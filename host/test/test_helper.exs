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
    File.mkdir_p!(Path.join(dir, "bin"))

    wasmtime =
      if runtime = runtime() do
        for name <- ["kettlecorn-launch", "kettlecorn-run"] do
          executable = Path.join([dir, "bin", name])
          File.rm(executable)
          File.ln_s!(Path.join([runtime, "bin", name]), executable)
        end

        Kettlecorn.Runtime.load!(runtime).manifest.tested_wasmtime
      else
        for name <- ["kettlecorn-launch", "kettlecorn-run"] do
          executable = Path.join([dir, "bin", name])
          File.write!(executable, "#!/bin/sh\nexit 1\n")
          File.chmod!(executable, 0o755)
        end

        "0.0.0"
      end

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
          "tested_with" => %{"wasmtime" => wasmtime}
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

defmodule TestProxy do
  @moduledoc false
  # An HTTP proxy on 127.0.0.1 that answers plain requests itself with
  # "proxied". It accepts CONNECT tunnels and closes them after the first
  # bytes through them. It sends the test process {:proxy, head} for each
  # request head, and {:tunnel, bytes} for those bytes.

  def start do
    test = self()

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false, reuseaddr: true])

    {:ok, port} = :inet.port(listener)
    spawn_link(fn -> loop(listener, test) end)
    port
  end

  defp loop(listener, test) do
    {:ok, socket} = :gen_tcp.accept(listener)
    head = read_head(socket, "")
    send(test, {:proxy, head})

    if String.starts_with?(head, "CONNECT") do
      :ok = :gen_tcp.send(socket, "HTTP/1.1 200 Connection established\r\n\r\n")
      {:ok, bytes} = :gen_tcp.recv(socket, 0, 10_000)
      send(test, {:tunnel, bytes})
    else
      reply = "HTTP/1.1 200 OK\r\ncontent-length: 7\r\nconnection: close\r\n\r\nproxied"
      :ok = :gen_tcp.send(socket, reply)
    end

    :gen_tcp.close(socket)
    loop(listener, test)
  end

  defp read_head(socket, head) do
    if String.contains?(head, "\r\n\r\n") do
      head
    else
      {:ok, data} = :gen_tcp.recv(socket, 0, 10_000)
      read_head(socket, head <> data)
    end
  end
end
