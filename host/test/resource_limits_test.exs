defmodule Kettlecorn.ResourceLimitsTest do
  # Each test boots its own VM in the launcher, see test_helper.exs. These
  # tests exhaust memory, fuel, and CPU, so they run on their own.
  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag timeout: 120_000

  # While parallel builds load the machine, a stopped VM can take several
  # seconds to finish shutting down.
  @teardown 30_000

  test "a memory bomb brings down only its own VM" do
    {:ok, vm} = Kettlecorn.start(TestRuntime.opts(max_memory: 128 * 1024 * 1024))
    ref = Process.monitor(vm)

    result =
      Kettlecorn.eval(
        vm,
        ~S'Enum.reduce(1..100, [], fn _, acc -> [:binary.copy("x", 10_000_000) | acc] end)',
        timeout: 30_000
      )

    assert {:error, {:vm_down, {:fatal, message} = reason}} = result
    assert message =~ "Cannot allocate"
    assert_receive {:DOWN, ^ref, :process, ^vm, {:shutdown, {:vm_down, ^reason}}}, @teardown
  end

  @tag timeout: 300_000
  test "a guest that keeps building large heaps doesn't fragment its memory" do
    {:ok, vm} = Kettlecorn.start(TestRuntime.opts(max_memory: 192 * 1024 * 1024))
    on_exit(fn -> Kettlecorn.stop(vm) end)

    code =
      ~S"for(i <- 1..100_000, do: {i, :rand.uniform()}) |> Enum.sort_by(&elem(&1, 1)) |> length()"

    for _ <- 1..60 do
      assert {:ok, %{"value" => 100_000}} = Kettlecorn.eval(vm, code, timeout: 30_000)
    end
  end

  test "max_lifetime stops the VM" do
    Process.flag(:trap_exit, true)

    case Kettlecorn.start_link(TestRuntime.opts(max_lifetime: 3_000)) do
      {:ok, _vm} -> assert_receive {:EXIT, _vm, {:shutdown, {:vm_down, :timeout}}}, 10_000
      {:error, {:vm_down, :timeout}} -> :ok
    end
  end

  test "max_fuel bounds the CPU a VM can use" do
    {:ok, vm} = Kettlecorn.start(TestRuntime.opts(max_fuel: 3_000_000_000))
    ref = Process.monitor(vm)
    assert {:ok, %{"value" => 2}} = Kettlecorn.eval(vm, "1 + 1")

    assert {:error, {:vm_down, :out_of_fuel}} =
             Kettlecorn.eval(vm, "Stream.repeatedly(fn -> 1 end) |> Stream.run()",
               timeout: 60_000
             )

    assert_receive {:DOWN, ^ref, :process, ^vm, {:shutdown, {:vm_down, :out_of_fuel}}}, @teardown
  end

  test "busy guests can't block a call forever" do
    vm = start_vm()
    # A guest process spinning outside the evaluator's control.
    {:ok, _} =
      Kettlecorn.eval(
        vm,
        "spawn(fn -> Stream.repeatedly(fn -> 1 end) |> Stream.run() end); :ok"
      )

    assert {:ok, %{"value" => 2}} = Kettlecorn.eval(vm, "1 + 1")
  end

  defp start_vm do
    {:ok, vm} = Kettlecorn.start(TestRuntime.opts())
    on_exit(fn -> Kettlecorn.stop(vm) end)
    vm
  end
end
