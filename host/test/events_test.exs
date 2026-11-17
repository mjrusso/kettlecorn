defmodule Kettlecorn.EventsTest do
  use ExUnit.Case, async: true

  @moduletag :integration
  @moduletag timeout: 120_000

  defp start_vm(opts) do
    {:ok, vm} = Kettlecorn.start(TestRuntime.opts([owner: self()] ++ opts))
    on_exit(fn -> Kettlecorn.stop(vm) end)
    vm
  end

  test "event count overflow stops the guest without delivering the excess" do
    vm = start_vm(max_pending_events: 2)

    assert {:error, {:vm_down, :event_queue_full}} =
             Kettlecorn.eval(vm, "for n <- 1..3, do: Kettlecorn.Host.send(n)")

    assert_receive {:kettlecorn, ^vm, {:message, 1}}
    assert_receive {:kettlecorn, ^vm, {:message, 2}}
    refute_receive {:kettlecorn, ^vm, {:message, 3}}
  end

  test "acknowledgments release the budget for continued delivery" do
    vm = start_vm(max_pending_events: 1, max_pending_event_bytes: 1_024)

    for n <- 1..10 do
      assert {:ok, _} = Kettlecorn.eval(vm, "Kettlecorn.Host.send(#{n})")
      assert_receive {:kettlecorn, ^vm, {:message, ^n}}
      Kettlecorn.acknowledge(vm)
    end
  end

  test "a small payload retaining a large envelope exhausts the byte budget" do
    vm = start_vm(max_pending_event_bytes: 10_000)

    code = ~S"""
    envelope = %{type: :vm_message, data: String.duplicate("x", 65), padding: String.duplicate("y", 200_000)}
    :wasm.send_raw(:erlang.term_to_binary(envelope))
    """

    assert {:error, {:vm_down, :event_queue_full}} = Kettlecorn.eval(vm, code)
    refute_receive {:kettlecorn, ^vm, {:message, _}}
  end

  test "another host process cannot acknowledge the owner's events" do
    vm = start_vm(max_pending_events: 1)
    assert {:ok, _} = Kettlecorn.eval(vm, "Kettlecorn.Host.send(1)")
    assert_receive {:kettlecorn, ^vm, {:message, 1}}
    Task.async(fn -> Kettlecorn.acknowledge(vm) end) |> Task.await()

    assert {:error, {:vm_down, :event_queue_full}} =
             Kettlecorn.eval(vm, "Kettlecorn.Host.send(2)")
  end
end
