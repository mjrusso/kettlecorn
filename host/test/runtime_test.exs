defmodule Kettlecorn.RuntimeTest do
  use ExUnit.Case, async: true
  alias Kettlecorn.Runtime

  @moduletag :tmp_dir

  test "rejects a runtime for another platform or missing executables", %{tmp_dir: dir} do
    runtime = TestRuntime.fixture(Path.join(dir, "runtime"), %{"platform" => "other-platform"})
    assert {:error, message} = Runtime.load(runtime)
    assert message =~ "runtime is for other-platform"

    for name <- ["kettlecorn-launch", "kettlecorn-run"] do
      TestRuntime.fixture(runtime)
      File.rm!(Path.join([runtime, "bin", name]))
      assert {:error, message} = Runtime.load(runtime)
      assert message =~ "no executable bin/#{name}"
    end
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

  test "cached release validation checks identity and uses the launcher's emulator name",
       %{tmp_dir: dir} do
    runtime =
      TestRuntime.fixture(Path.join(dir, "runtime"), %{
        "kettlecorn" => Runtime.version(),
        "tested_with" => %{"wasmtime" => "0.0.0"}
      })

    File.write!(Path.join(runtime, "launch/module"), "beam.wasm \r\n")
    assert {:ok, _} = Runtime.load_release(runtime)

    File.write!(Path.join(runtime, "launch/module"), "beam.wasm\nbeam-http.wasm")
    assert {:error, message} = Runtime.load_release(runtime)
    assert message =~ "doesn't name one emulator"

    TestRuntime.fixture(runtime, %{"kettlecorn" => "0.0.0"})
    assert {:error, message} = Runtime.load_release(runtime)
    assert message =~ "expected Kettlecorn runtime version"
  end

  test "install verifies the digest and the staged release before publishing", %{tmp_dir: dir} do
    runtime = TestRuntime.fixture(Path.join(dir, "source"), %{"kettlecorn" => "0.0.0"})

    for name <- ["kettlecorn-launch", "kettlecorn-run"] do
      path = Path.join([runtime, "bin", name])
      File.rm!(path)
      File.write!(path, "")
      File.chmod!(path, 0o755)
    end

    archive = Path.join(dir, "runtime.tar.gz")
    assert :ok = :erl_tar.create(~c"#{archive}", [{~c"runtime", ~c"#{runtime}"}], [:compressed])

    destination = Path.join(dir, "installed")
    checksum = :sha256 |> :crypto.hash(File.read!(archive)) |> Base.encode16(case: :lower)
    install = &Kettlecorn.Install.runtime([dir: destination, archive: &1], fn _ -> {:ok, &2} end)

    assert {:error, "reading " <> _} = install.(Path.join(dir, "missing.tar.gz"), checksum)

    assert {:error, message} = install.(archive, "bad checksum")
    assert message =~ "SHA-256 #{checksum}, expected bad checksum"
    assert {:error, :enoent} = File.lstat(destination <> ".versions")

    assert {:error, message} = install.(archive, checksum)

    assert message =~ "expected Kettlecorn runtime version"
    assert {:error, :enoent} = File.lstat(destination)
    assert File.ls!(destination <> ".versions") == []
  end

  test "mix kettlecorn.install rejects a path given without --archive" do
    assert_raise Mix.Error, ~r/--archive PATH/, fn ->
      Mix.Tasks.Kettlecorn.Install.run(["runtime.tar.gz"])
    end
  end

  test "install reports when the generation directory cannot be created", %{tmp_dir: dir} do
    destination = Path.join(dir, "runtime")
    generations = destination <> ".versions"
    File.write!(generations, "occupied")
    archive = Path.join(dir, "runtime.tar.gz")
    File.write!(archive, "fixture")
    checksum = :sha256 |> :crypto.hash("fixture") |> Base.encode16(case: :lower)

    assert {:error, "cannot create generation directory " <> detail} =
             Kettlecorn.Install.runtime([dir: destination, archive: archive], fn _ ->
               {:ok, checksum}
             end)

    assert detail =~ generations
    assert File.read!(generations) == "occupied"
    assert {:error, :enoent} = File.lstat(destination)
  end
end
