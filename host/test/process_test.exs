defmodule Kettlecorn.ProcessTest do
  use ExUnit.Case, async: true
  @moduletag :integration
  @moduletag :tmp_dir

  test "cancelled callers release admission and late guest replies are ignored" do
    {:ok, vm} = Kettlecorn.start(TestRuntime.opts(owner: self(), max_pending_requests: 1))
    on_exit(fn -> Kettlecorn.stop(vm) end)

    assert {:ok, _} =
             Kettlecorn.eval(vm, """
             defmodule PendingServer do
               use GenServer
               def init(nil), do: {:ok, []}
               def handle_call(request, from, pending) do
                 Kettlecorn.Host.send(request)
                 {:noreply, [from | pending]}
               end
               def handle_cast(:reply, pending) do
                 Enum.each(pending, &GenServer.reply(&1, "late"))
                 {:noreply, []}
               end
             end
             GenServer.start(PendingServer, nil, name: :pending_server)
             :ok
             """)

    for timeout <- [:infinity, 60_000, :infinity, 60_000] do
      caller = spawn(fn -> Kettlecorn.call(vm, "pending_server", "waiting", timeout) end)
      on_exit(fn -> Process.exit(caller, :kill) end)
      assert_receive {:kettlecorn, ^vm, {:message, "waiting"}}, 5_000
      Kettlecorn.acknowledge(vm)
      assert {:error, :request_queue_full} = Kettlecorn.eval(vm, "1")
      assert {:error, :request_queue_full} = Kettlecorn.send(vm, "pending_server", "rejected")
      Process.exit(caller, :kill)
      await_no_requests(vm, System.monotonic_time(:millisecond) + 5_000)
    end

    assert :ok = Kettlecorn.cast(vm, "pending_server", :reply)
    assert {:ok, %{"value" => 2}} = Kettlecorn.eval(vm, "1 + 1")
    assert Process.info(vm, :monitors) == {:monitors, []}
  end

  test "stopping a busy guest ends the launcher before removing its instance", %{tmp_dir: tmp} do
    instances = Path.join(tmp, "instances")
    {:ok, vm} = Kettlecorn.start(TestRuntime.opts(instances_dir: instances))
    on_exit(fn -> Kettlecorn.stop(vm) end)

    {:ok, _} =
      Kettlecorn.eval(
        vm,
        "spawn(fn -> Process.sleep(500); Process.flag(:priority, :max); Stream.repeatedly(fn -> 1 end) |> Stream.run() end)"
      )

    Kettlecorn.write_stdin(vm, :binary.copy("x", 1_000_000))
    Kettlecorn.take_output(vm)
    assert :ok = Kettlecorn.stop(vm)
    assert File.ls!(instances) == []
    {processes, 0} = System.cmd("ps", ["-A", "-o", "args="])
    refute processes =~ instances
  end

  defp await_no_requests(vm, deadline) do
    if map_size(:sys.get_state(vm).requests.entries) != 0 do
      assert System.monotonic_time(:millisecond) < deadline
      Process.sleep(10)
      await_no_requests(vm, deadline)
    end
  end
end
