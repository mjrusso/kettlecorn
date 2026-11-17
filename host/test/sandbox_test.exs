defmodule Kettlecorn.SandboxTest do
  use ExUnit.Case, async: true
  alias Kettlecorn.Sandbox

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    %{runtime: TestRuntime.fixture(Path.join(dir, "runtime"))}
  end

  @tag :integration
  test "builds a launcher command with limits and a private root", %{runtime: runtime} do
    instance =
      Sandbox.new(
        runtime: runtime,
        max_memory: 1024,
        max_lifetime: 2000,
        schedulers: 2,
        env: %{"KETTLECORN_FRAMED" => "0", "LANG" => "C", "CUSTOM" => "value"}
      )
      |> Sandbox.Instance.prepare()

    on_exit(fn -> Sandbox.Instance.cleanup(instance) end)
    [exe | args] = Sandbox.Instance.command(instance)
    assert exe == Path.join(runtime, "bin/kettlecorn-launch")
    joined = Enum.join(args, " ")
    assert joined =~ "--max-memory 1024 --schedulers 2 --lifetime-ms 2000"
    refute "--network" in args
    assert joined =~ "--env LANG=C"
    assert joined =~ "--env CUSTOM=value"
    assert "--framed" in args
    root = Path.join(instance.dir, "root")
    assert joined =~ "--root #{root}"

    refute joined =~ runtime <> "/root"
    assert File.read!(Path.join(root, "lib/kernel/ebin/x.beam")) == "x"
    assert File.stat!(instance.dir).mode |> Bitwise.band(0o777) == 0o700
    Sandbox.Instance.cleanup(instance)
    refute File.exists?(instance.dir)
  end

  @tag :integration
  test "the grants enable launcher capabilities", %{runtime: runtime} do
    instance =
      Sandbox.new(runtime: runtime, network: true, http: true)
      |> Sandbox.Instance.prepare()

    on_exit(fn -> Sandbox.Instance.cleanup(instance) end)
    joined = instance |> Sandbox.Instance.command() |> Enum.join(" ")
    assert joined =~ "--network --http"
  end

  test "rejects unknown options, and invalid ones for the VM", %{runtime: runtime} do
    assert_raise ArgumentError, ~r/unknown options.*:max_memroy/, fn ->
      Sandbox.new(runtime: runtime, max_memroy: 1024)
    end

    base = [runtime: runtime]

    assert_raise ArgumentError, ~r/unknown options.*:max_lifetme/, fn ->
      Kettlecorn.start([max_lifetme: 1_000] ++ base)
    end

    for {key, value} <- [output_limit: -1, max_message_size: 0, boot_timeout: "1", owner: :me] do
      assert_raise ArgumentError, ~r/#{inspect(key)} option/, fn ->
        Kettlecorn.start([{key, value} | base])
      end
    end
  end

  test "grants must be booleans, limits positive integers", %{runtime: runtime} do
    for {key, value} <- [
          network: "false",
          http: 1,
          max_memory: 0,
          max_fuel: -1,
          schedulers: :infinity,
          code_paths: [~c"/a"],
          emulator_flags: ["-hms", 1000],
          apps: [nil],
          env: %{"A=B" => "c"},
          env: [{"A", "line\nbreak"}],
          env: %{"A" => 1},
          app: :my_app
        ] do
      assert_raise ArgumentError, ~r/#{inspect(key)} option/, fn ->
        Sandbox.new([{key, value}, runtime: runtime])
      end
    end

    assert %Sandbox{max_lifetime: :infinity} =
             Sandbox.new(runtime: runtime, max_lifetime: :infinity)
  end

  test "refuses a runtime with another protocol version, or none", %{runtime: runtime} do
    other = Kettlecorn.Runtime.protocol_version() + 1

    File.write!(
      Path.join(runtime, "manifest.json"),
      JSON.encode!(%{"kettlecorn" => "9.9.9", "protocol" => other})
    )

    assert_raise ArgumentError, ~r/speaks protocol #{other}/, fn ->
      Sandbox.new(runtime: runtime)
    end

    File.rm!(Path.join(runtime, "manifest.json"))

    assert_raise ArgumentError, ~r/not a Kettlecorn runtime/, fn ->
      Sandbox.new(runtime: runtime)
    end
  end

  test "refuses an incomplete runtime", %{runtime: runtime} do
    for {break, message} <- [
          {&File.rm!(Path.join(&1, "launch/init-args")),
           ~r/not a complete runtime \(no .*launch\/init-args\)/},
          {&File.write!(Path.join(&1, "launch/env"), "HOME\n"),
           ~r/launch\/env has a line that isn't NAME=value/},
          {&File.write!(Path.join(&1, "launch/module"), "a.wasm\nb.wasm\n"),
           ~r/launch\/module doesn't name one emulator/},
          {&File.rm!(Path.join(&1, "beam-http.wasm")),
           ~r/not a complete runtime \(no beam-http.wasm\)/},
          {&File.rm_rf!(Path.join(&1, "root")), ~r/not a complete runtime \(no root\/\)/}
        ] do
      broken = "#{runtime}-broken"
      File.rm_rf!(broken)
      File.cp_r!(runtime, broken)
      break.(broken)

      assert_raise ArgumentError, message, fn ->
        Sandbox.new(runtime: broken)
      end

      File.rm_rf!(broken)
    end
  end
end
