defmodule Kettlecorn.RuntimeTest do
  use ExUnit.Case, async: true
  alias Kettlecorn.Runtime

  @moduletag :tmp_dir

  test "rejects a runtime for another platform or without its launcher", %{tmp_dir: dir} do
    runtime = TestRuntime.fixture(Path.join(dir, "runtime"), %{"platform" => "other-platform"})
    assert {:error, message} = Runtime.load(runtime)
    assert message =~ "runtime is for other-platform"
    TestRuntime.fixture(runtime)
    File.rm!(Path.join(runtime, "bin/kettlecorn-launch"))
    assert {:error, message} = Runtime.load(runtime)
    assert message =~ "no executable bin/kettlecorn-launch"
  end

  @tag :integration
  test "the runtime's manifest: protocol, imports and tested wasmtime" do
    manifest = Runtime.load!(TestRuntime.runtime()).manifest
    assert manifest.protocol == Runtime.protocol_version()
    assert manifest.kettlecorn == Runtime.version()

    assert File.read!(Path.join(TestRuntime.runtime(), "launch/engine-version")) =~
             manifest.tested_wasmtime

    %{"beam.wasm" => plain, "beam-http.wasm" => http} = manifest.imports
    assert "wasi:sockets/types@0.3.2" in plain
    refute Enum.any?(plain, &String.starts_with?(&1, "wasi:http/"))
    assert Enum.any?(http, &String.starts_with?(&1, "wasi:http/client@"))
    assert plain -- http == []
  end
end
