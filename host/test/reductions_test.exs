defmodule Kettlecorn.ReductionsTest do
  use ExUnit.Case, async: true

  @moduletag :integration
  @moduletag timeout: 300_000

  # One process that makes host calls between pieces of work.
  @code ~S"""
  for i <- 1..1_000 do
    Enum.map(1..2_000, &(&1 * i))
    {:ok, _} = Kettlecorn.Host.call("tick", %{"i" => i}, timeout: 60_000)
  end
  """

  test "reply delays and scheduler contention preserve the reduction stopping point" do
    immediate = fn -> 0 end
    random = fn -> :rand.uniform(10) end

    runs =
      for {delay, busy} <- [{immediate, false}, {random, false}, {immediate, true}] do
        {:ok, vm} = Kettlecorn.start_link(TestRuntime.opts(owner: self()))

        # An earlier evaluation, the same in every run, spawns a process. With
        # busy, it keeps running and competes for the scheduler; its work isn't
        # charged to the evaluation below.
        {:ok, _} =
          Kettlecorn.eval(
            vm,
            "spawn(fn -> if busy, do: Stream.repeatedly(fn -> :x end) |> Stream.run() end)",
            binding: %{busy: busy}
          )

        task =
          Task.async(fn ->
            Kettlecorn.eval(vm, @code, max_reductions: 1_500_000, timeout: 240_000)
          end)

        result = serve(vm, task, delay, 0)
        Kettlecorn.stop(vm)
        result
      end

    assert [{ticks, {:error, %{"kind" => "reductions"}}} = first | rest] = runs
    assert ticks > 0
    assert rest == [first, first]
  end

  test "max_reductions must fit the guest's signed 64-bit count" do
    assert_raise ArgumentError, ~r/max_reductions/, fn ->
      Kettlecorn.eval(self(), "1", max_reductions: 2 ** 63)
    end
  end

  test "max_reductions stops an evaluation and the processes it spawned" do
    vm = start_vm()

    code = ~S"""
    spawn(fn ->
      Process.register(self(), :kettlecorn_spinner)
      Stream.repeatedly(fn -> :x end) |> Stream.run()
    end)
    Stream.repeatedly(fn -> :x end) |> Stream.run()
    """

    assert {:error, %{"kind" => "reductions", "reductions" => used}} =
             Kettlecorn.eval(vm, code, max_reductions: 1_000_000, timeout: 60_000)

    # Each process is charged at most one time slice before it is stopped.
    assert used > 1_000_000 and used < 1_020_000

    assert {:ok, %{"value" => nil, "reductions" => reductions}} =
             Kettlecorn.eval(vm, "Process.whereis(:kettlecorn_spinner)")

    assert reductions > 0
  end

  test "max_reductions stops untraced descendants when they next run" do
    vm = start_vm()

    # The grandchild is spawned without tracing, so the capture can't
    # kill it; it stays blocked until the evaluation has failed.
    code = ~S"""
    parent = self()

    spawn(fn ->
      :erlang.trace(self(), false, [:all])
      pid = spawn(fn -> receive do: (:go -> Stream.repeatedly(fn -> :x end) |> Stream.run()) end)
      Process.register(pid, :kettlecorn_sleeper)
      send(parent, :ready)
    end)

    receive do: (:ready -> Stream.repeatedly(fn -> :x end) |> Stream.run())
    """

    assert {:error, %{"kind" => "reductions"}} =
             Kettlecorn.eval(vm, code, max_reductions: 1_000_000, timeout: 60_000)

    assert {:ok, %{"value" => :killed}} =
             Kettlecorn.eval(
               vm,
               ~S"""
               pid = Process.whereis(:kettlecorn_sleeper)
               ref = Process.monitor(pid)
               send(pid, :go)
               receive do
                 {:DOWN, ^ref, _, _, reason} -> reason
               after
                 10_000 -> :alive
               end
               """,
               timeout: 30_000
             )
  end

  test "max_reductions charges output callbacks" do
    vm = start_vm()

    code = ~S"""
    spin = Stream.repeatedly(fn -> :x end)
    :io.request(Process.group_leader(), {:put_chars, :unicode, Stream, :run, [spin]})
    """

    assert {:error, %{"kind" => "reductions"}} =
             Kettlecorn.eval(vm, code, max_reductions: 1_000_000, timeout: 60_000)
  end

  defp start_vm do
    {:ok, vm} = Kettlecorn.start_link(TestRuntime.opts())
    on_exit(fn -> Kettlecorn.stop(vm) end)
    vm
  end

  defp serve(vm, task, delay, ticks) do
    receive do
      {:kettlecorn, ^vm, {:host_call, reply_to, "tick", %{"i" => i}}} ->
        Kettlecorn.acknowledge(vm)
        Process.sleep(delay.())
        :ok = Kettlecorn.reply(vm, reply_to, {:ok, i})
        serve(vm, task, delay, i)

      {:kettlecorn, ^vm, _event} ->
        Kettlecorn.acknowledge(vm)
        serve(vm, task, delay, ticks)

      {ref, result} when ref == task.ref ->
        Process.demonitor(ref, [:flush])
        {ticks, result}
    end
  end
end
