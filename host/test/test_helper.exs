defmodule TestRuntime do
  # Integration tests need the runtime built by the flake and the bundled launcher:
  #
  #   KETTLECORN_RUNTIME=$(nix build ..#runtime --no-link --print-out-paths) mix test
  #
  # (or `just test` from the kettlecorn directory).
  def runtime, do: System.get_env("KETTLECORN_RUNTIME")

  def opts(extra \\ []) do
    instances = Path.join(System.tmp_dir!(), "kettlecorn-test")
    File.mkdir_p!(instances)
    Keyword.merge([runtime: runtime(), instances_dir: instances], extra)
  end

  def fixture(dir, overrides \\ %{}) do
    File.mkdir_p!(Path.join(dir, "root/lib/kernel/ebin"))
    File.mkdir_p!(Path.join(dir, "root/lib/stdlib/ebin"))
    File.write!(Path.join(dir, "root/lib/kernel/ebin/x.beam"), "x")
    for module <- ["beam.wasm", "beam-http.wasm"], do: File.write!(Path.join(dir, module), "")

    manifest =
      Map.merge(
        %{
          "kettlecorn" => "0.0.0",
          "protocol" => Kettlecorn.Runtime.protocol_version(),
          "otp" => System.otp_release(),
          "elixir" => System.version(),
          "imports" => %{},
          "platform" => elem(Kettlecorn.Platform.current(), 1),
          "tested_with" => %{"wasmtime" => "50.0.0"}
        },
        overrides
      )

    for file <- ["manifest.json", "root/manifest.json"],
        do: File.write!(Path.join(dir, file), JSON.encode!(manifest))

    launch = %{
      "emulator" => ["-Mea", "min"],
      "init" => ["-root", "/"]
    }

    File.mkdir_p!(Path.join(dir, "launch"))

    for {name, args} <- launch,
        do: File.write!(Path.join(dir, "launch/#{name}-args"), Enum.join(args, "\n") <> "\n")

    File.write!(
      Path.join(dir, "launch/env"),
      "HOME=/home\nLANG=C.UTF-8\nKETTLECORN_CACERTFILE=/etc/ssl/cert.pem\n"
    )

    File.write!(Path.join(dir, "launch/module"), "beam.wasm\n")
    File.write!(Path.join(dir, "launch/http-module"), "beam-http.wasm\n")
    File.mkdir_p!(Path.join(dir, "bin"))
    launcher = Path.join(dir, "bin/kettlecorn-launch")

    if runtime = runtime() do
      File.rm(launcher)
      File.ln_s!(Path.join(runtime, "bin/kettlecorn-launch"), launcher)
    else
      File.write!(launcher, "#!/bin/sh\nexit 1\n")
      File.chmod!(launcher, 0o755)
    end

    dir
  end

  def available? do
    runtime() != nil and File.dir?(runtime()) and
      File.regular?(Path.join(runtime(), "bin/kettlecorn-launch"))
  end
end

examples? = System.get_env("KETTLECORN_EXAMPLES") != nil

cond do
  not TestRuntime.available?() ->
    IO.puts("KETTLECORN_RUNTIME not available: skipping integration tests")
    ExUnit.start(exclude: [:integration])

  !examples? ->
    IO.puts("KETTLECORN_EXAMPLES not set: skipping the example app tests")
    ExUnit.start(exclude: [:examples])

  true ->
    ExUnit.start()
end
