defmodule Kettlecorn.HostHandlersTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog

  @moduletag :integration
  @moduletag timeout: 120_000

  defmodule Handler do
    @behaviour Kettlecorn.HostHandler

    @impl true
    def init({test, :block_cancel}), do: {:ok, %{test: test, count: 0, block_cancel: true}}
    def init(test), do: {:ok, %{test: test, count: 0, block_cancel: false}}

    @impl true
    def handle_host_call("count", _args, _from, state),
      do: {:reply, {:ok, state.count + 1}, %{state | count: state.count + 1}}

    def handle_host_call("later", _args, from, state) do
      send(state.test, {:later, from})
      {:noreply, state}
    end

    def handle_host_call("block", %{"n" => n}, _from, state) do
      send(state.test, {:started, n, self()})

      receive do
        :go -> {:reply, {:ok, n}, state}
      end
    end

    def handle_host_call("invalid", _args, _from, state), do: {:reply, :invalid, state}

    def handle_host_call("huge", _args, _from, state),
      do: {:reply, {:ok, :binary.copy("x", Kettlecorn.Protocol.max_input_size())}, state}

    @impl true
    def handle_cancel(from, state) do
      send(state.test, {:cancelled, from})

      if state.block_cancel do
        send(state.test, {:blocked, self()})

        receive do
          :go -> :ok
        end
      end

      {:noreply, state}
    end
  end

  defp start_vm(opts) do
    {:ok, vm} = Kettlecorn.start_link(TestRuntime.opts(opts))
    on_exit(fn -> Kettlecorn.stop(vm) end)
    vm
  end

  defp value(vm, code) do
    assert {:ok, %{"value" => value}} = Kettlecorn.eval(vm, code, timeout: 30_000)
    value
  end

  # Reports its pid to the test, then answers once the test sends :go.
  defp waiting(test) do
    fn _args ->
      send(test, {:waiting, self()})

      receive do
        :go -> {:ok, 1}
      end
    end
  end

  test "functions answer host calls by name" do
    vm =
      start_vm(
        handlers: %{
          "double" => fn %{"n" => n} -> {:ok, 2 * n} end,
          "raises" => fn _args -> raise "broken" end,
          "exits" => fn _args -> Process.exit(self(), :kill) end,
          "invalid" => fn _args -> :invalid end
        },
        # Each call must release its slot for the next to run.
        max_host_calls: 1
      )

    log =
      capture_log(fn ->
        assert value(vm, ~S"""
               for name <- ["double", "raises", "exits", "invalid", "missing", "double"],
                   do: Kettlecorn.Host.call(name, %{"n" => 21})
               """) == [
                 {:ok, 42},
                 {:error, "host function failed"},
                 {:error, "host function failed"},
                 {:error, "invalid host function result"},
                 {:error, "no host handler"},
                 {:ok, 42}
               ]
      end)

    assert log =~ "broken"
  end

  test "max_host_calls bounds the calls in progress" do
    test = self()
    vm = start_vm(handlers: %{"wait" => waiting(test)}, max_host_calls: 1)

    first =
      Task.async(fn -> value(vm, ~S|Kettlecorn.Host.call("wait", %{}, timeout: 30_000)|) end)

    assert_receive {:waiting, pid}, 30_000

    assert value(vm, ~S|Kettlecorn.Host.call("wait")|) ==
             {:error, "host call capacity exhausted"}

    send(pid, :go)
    assert Task.await(first, 30_000) == {:ok, 1}
    # The finished call released its slot.
    task = Task.async(fn -> value(vm, ~S|Kettlecorn.Host.call("wait", %{}, timeout: 30_000)|) end)
    assert_receive {:waiting, pid}, 30_000
    send(pid, :go)
    assert Task.await(task, 30_000) == {:ok, 1}
  end

  test "a function stops when the guest stops waiting for its call" do
    test = self()
    vm = start_vm(handlers: %{"wait" => waiting(test)})

    assert value(vm, ~S|Kettlecorn.Host.call("wait", %{}, timeout: 100)|) == {:error, :timeout}
    assert_receive {:waiting, pid}, 30_000
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, reason} when reason in [:killed, :noproc], 30_000

    # The caller exits first: the evaluation times out.
    assert {:error, %{"kind" => "timeout"}} =
             Kettlecorn.eval(vm, ~S|Kettlecorn.Host.call("wait", %{}, timeout: 60_000)|,
               timeout: 500
             )

    assert_receive {:waiting, pid}, 30_000
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, reason} when reason in [:killed, :noproc], 30_000
  end

  test "a behaviour answers calls in one process, now or later, and hears of cancellations" do
    vm = start_vm(handler: {Handler, self()})

    assert value(vm, ~S|{Kettlecorn.Host.call("count"), Kettlecorn.Host.call("count")}|) ==
             {{:ok, 1}, {:ok, 2}}

    task =
      Task.async(fn -> value(vm, ~S|Kettlecorn.Host.call("later", %{}, timeout: 30_000)|) end)

    assert_receive {:later, from}, 30_000
    :ok = Kettlecorn.HostHandler.reply(from, {:ok, "done"})
    assert Task.await(task, 30_000) == {:ok, "done"}

    assert value(vm, ~S|Kettlecorn.Host.call("later", %{}, timeout: 100)|) == {:error, :timeout}
    assert_receive {:later, from}, 30_000
    assert_receive {:cancelled, ^from}, 30_000
  end

  test "a behaviour's calls queue in the VM, and a call cancelled while queued never starts" do
    vm = start_vm(handler: {Handler, self()}, max_host_calls: 2)

    first =
      Task.async(fn ->
        value(vm, ~S|Kettlecorn.Host.call("block", %{"n" => 1}, timeout: 30_000)|)
      end)

    assert_receive {:started, 1, handler}, 30_000

    # Each call waits in the VM's queue behind the first, times out and is
    # dropped; one at a time fits beside the first.
    assert value(vm, ~S"""
           for n <- 2..6, do: Kettlecorn.Host.call("block", %{"n" => n}, timeout: 100)
           """) == List.duplicate({:error, :timeout}, 5)

    # With the first call and one queued call, the slots are full.
    assert value(vm, ~S"""
           task = Task.async(fn -> Kettlecorn.Host.call("block", %{"n" => 7}, timeout: 2_000) end)
           Process.sleep(500)
           {Kettlecorn.Host.call("block", %{"n" => 8}), Task.await(task, 5_000)}
           """) == {{:error, "host call capacity exhausted"}, {:error, :timeout}}

    send(handler, :go)
    assert Task.await(first, 30_000) == {:ok, 1}
    refute_receive {:started, _n, _pid}, 500
  end

  test "a call queued while the behaviour handles a cancellation never starts if it expires" do
    vm = start_vm(handler: {Handler, {self(), :block_cancel}})

    assert value(vm, ~S|Kettlecorn.Host.call("later", %{}, timeout: 100)|) == {:error, :timeout}
    assert_receive {:later, from}, 30_000
    assert_receive {:cancelled, ^from}, 30_000
    assert_receive {:blocked, handler}, 30_000

    assert value(vm, ~S|Kettlecorn.Host.call("block", %{"n" => 2}, timeout: 100)|) ==
             {:error, :timeout}

    send(handler, :go)
    assert value(vm, ~S|Kettlecorn.Host.call("count")|) == {:ok, 1}
    refute_received {:started, 2, _pid}
  end

  test "a behaviour's invalid and oversized results answer errors" do
    vm = start_vm(handler: {Handler, self()})

    log =
      capture_log(fn ->
        assert value(vm, ~S|{Kettlecorn.Host.call("invalid"), Kettlecorn.Host.call("huge")}|) ==
                 {{:error, "invalid host function result"}, {:error, "host reply too large"}}
      end)

    assert log =~ ":invalid"
  end

  test "a call fails at once if the guest's reply router stops, and later calls work" do
    vm = start_vm(owner: self())

    task =
      Task.async(fn ->
        value(vm, ~S|Kettlecorn.Host.call("stuck", %{}, timeout: :infinity)|)
      end)

    assert_receive {:kettlecorn, ^vm, {:host_call, stuck, "stuck", %{}}}, 30_000
    Kettlecorn.acknowledge(vm)
    # Waits for the replacement router, so the next call goes through it
    # rather than straight to its caller.
    restart = ~S"""
    old = Process.whereis(:kettlecorn_host_calls)
    Process.exit(old, :kill)

    Stream.repeatedly(fn ->
      Process.sleep(10)
      Process.whereis(:kettlecorn_host_calls)
    end)
    |> Enum.find(&(&1 && &1 != old))
    |> is_pid()
    """

    assert {:ok, %{"value" => true}} = Kettlecorn.eval(vm, restart, timeout: 30_000)
    assert Task.await(task, 30_000) == {:error, :interrupted}
    assert_receive {:kettlecorn, ^vm, {:host_call_cancel, ^stuck}}, 30_000
    Kettlecorn.acknowledge(vm)

    task = Task.async(fn -> value(vm, ~S|Kettlecorn.Host.call("next")|) end)
    assert_receive {:kettlecorn, ^vm, {:host_call, next, "next", %{}}}, 30_000
    Kettlecorn.acknowledge(vm)
    :ok = Kettlecorn.reply(vm, next, {:ok, "after"})
    assert Task.await(task, 30_000) == {:ok, "after"}
  end

  test "an invalid timeout raises before the call is sent" do
    vm = start_vm(owner: self())

    code = ~S"""
    for timeout <- [-1, 4_294_967_296, 1.5, :never] do
      try do
        Kettlecorn.Host.call("never", %{}, timeout: timeout)
      rescue
        ArgumentError -> :raised
      end
    end
    """

    assert value(vm, code) == [:raised, :raised, :raised, :raised]
    refute_received {:kettlecorn, ^vm, {:host_call, _reply_to, "never", _args}}
  end

  test "an owner hears of a cancellation, and the guest drops the owner's late reply" do
    vm = start_vm(owner: self())

    # The second call's reply arrives after the late one, so by then the
    # guest has handled the late reply.
    code = ~S"""
    result = Kettlecorn.Host.call("slow", %{}, timeout: 100)
    {:ok, "after"} = Kettlecorn.Host.call("next", %{}, timeout: 30_000)
    {result, Process.info(self(), :messages)}
    """

    task = Task.async(fn -> value(vm, code) end)
    assert_receive {:kettlecorn, ^vm, {:host_call, slow, "slow", %{}}}, 30_000
    Kettlecorn.acknowledge(vm)
    assert_receive {:kettlecorn, ^vm, {:host_call_cancel, ^slow}}, 30_000
    Kettlecorn.acknowledge(vm)
    :ok = Kettlecorn.reply(vm, slow, {:ok, "late"})
    assert_receive {:kettlecorn, ^vm, {:host_call, next, "next", %{}}}, 30_000
    Kettlecorn.acknowledge(vm)
    :ok = Kettlecorn.reply(vm, next, {:ok, "after"})
    assert Task.await(task, 30_000) == {{:error, :timeout}, {:messages, []}}
  end

  test "handlers and handler can't be combined" do
    assert_raise ArgumentError, ~r/can't be combined/, fn ->
      Kettlecorn.start_link(TestRuntime.opts(handlers: %{}, handler: {Handler, self()}))
    end
  end
end
