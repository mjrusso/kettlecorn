defmodule Kettlecorn.ProcessTest do
  use ExUnit.Case, async: true
  @moduletag :integration
  @moduletag :tmp_dir

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
end
