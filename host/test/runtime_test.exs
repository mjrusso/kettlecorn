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
    assert {:error, message} = Runtime.lookup_cache(runtime)
    assert message =~ "expected Kettlecorn runtime version"

    File.rm!(Path.join(runtime, "manifest.json"))
    assert {:error, message} = Runtime.lookup_cache(runtime)
    assert message =~ "no manifest.json"
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

  test "the installer chooses the proxy for each URL it follows", %{tmp_dir: dir} do
    proxy = TestProxy.start()
    # A loopback mirror, reached directly, that redirects to a proxied host.
    # 127.notexample.test is a name, not a loopback address.
    mirror = start_redirect("http://127.notexample.test/archive")

    script = """
    Application.put_env(:kettlecorn, :release_base_url, "http://127.0.0.1:#{mirror}/releases")
    IO.inspect(Kettlecorn.Install.runtime([dir: #{inspect(Path.join(dir, "runtime"))}], fn _ -> {:ok, "0"} end))
    """

    # A no_proxy domain matches on a label boundary: not notexample.test.
    env =
      [
        {"MIX_ENV", "test"},
        # "é" and "p:ss", percent-encoded.
        {"http_proxy", "http://%C3%A9:p%3Ass@127.0.0.1:#{proxy}"},
        {"no_proxy", ".example.test"}
      ] ++ for name <- ~w(HTTP_PROXY https_proxy HTTPS_PROXY NO_PROXY), do: {name, nil}

    output = run_script(script, env)

    # The proxy's reply isn't the archive.
    assert output =~ "SHA-256"
    assert_received {:proxy, "GET http://127.notexample.test/archive HTTP/1.1" <> head}
    assert head =~ ~r/proxy-authorization: Basic #{Base.encode64("é:p:ss")}\r\n/i
    refute_received {:proxy, _}
  end

  test "only the final response's location is followed", %{tmp_dir: dir} do
    proxy = TestProxy.start()

    mirror =
      start_server(
        "HTTP/1.1 103 Early Hints\r\nlocation: http://wrong.test/\r\n\r\n" <>
          "HTTP/1.1 302 Found\r\nlocation: http://kettlecorn.test/final\r\ncontent-length: 0\r\n\r\n"
      )

    script = """
    Application.put_env(:kettlecorn, :release_base_url, "http://127.0.0.1:#{mirror}/releases")
    IO.inspect(Kettlecorn.Install.runtime([dir: #{inspect(Path.join(dir, "runtime"))}], fn _ -> {:ok, "0"} end))
    """

    assert run_script(script, proxy_env("http://127.0.0.1:#{proxy}")) =~ "SHA-256"
    assert_received {:proxy, "GET http://kettlecorn.test/final HTTP/1.1" <> _}
  end

  test "no_proxy ignores a trailing root dot", %{tmp_dir: dir} do
    proxy = TestProxy.start()
    mirror = start_redirect("http://kettlecorn.test./archive")

    script = """
    Application.put_env(:kettlecorn, :release_base_url, "http://127.0.0.1:#{mirror}/releases")
    IO.inspect(Kettlecorn.Install.runtime([dir: #{inspect(Path.join(dir, "runtime"))}], fn _ -> {:ok, "0"} end))
    """

    env =
      for {name, value} <- proxy_env("http://127.0.0.1:#{proxy}"),
          do: if(name == "no_proxy", do: {name, "kettlecorn.test"}, else: {name, value})

    # Reached directly, the made-up host doesn't resolve.
    run_script(script, env)
    refute_received {:proxy, _}
  end

  test "malformed download URLs and redirects return an error", %{tmp_dir: dir} do
    install = fn base ->
      run_script(
        """
        Application.put_env(:kettlecorn, :release_base_url, #{inspect(base)})
        IO.inspect(Kettlecorn.Install.runtime([dir: #{inspect(Path.join(dir, "runtime"))}], fn _ -> {:ok, "0"} end))
        """,
        proxy_env(nil)
      )
    end

    error = "not an http:// or https:// URL with a host"
    assert install.("http:///releases") =~ error
    assert install.("http://127.0.0.1:#{start_redirect("http:///elsewhere")}/releases") =~ error

    assert install.(
             "http://127.0.0.1:#{start_redirect("http://mirror.example:wrong/archive")}/releases"
           ) =~
             "invalid redirect location"
  end

  test "an unsupported proxy returns an error that hides its credentials", %{tmp_dir: dir} do
    script = """
    Application.put_env(:kettlecorn, :release_base_url, "http://kettlecorn.test/releases")
    IO.inspect(Kettlecorn.Install.runtime([dir: #{inspect(Path.join(dir, "runtime"))}], fn _ -> {:ok, "0"} end))
    """

    output = run_script(script, proxy_env("https://user:s3cret@127.0.0.1:3128"))
    assert output =~ "invalid HTTP proxy in http_proxy: only http:// proxies are supported"
    refute output =~ "s3cret"

    output = run_script(script, proxy_env("http://user:s3cret@127.0.0.1:wrong"))
    assert output =~ "invalid HTTP proxy in http_proxy: bad host or port"
    refute output =~ "s3cret"
  end

  test "a stalled download doesn't delay another", %{tmp_dir: dir} do
    # The proxy holds the first request open, and answers the second.
    script = """
    {:ok, listener} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false])
    {:ok, port} = :inet.port(listener)
    System.put_env("http_proxy", "http://127.0.0.1:\#{port}")
    script = self()

    spawn_link(fn ->
      {:ok, stalled} = :gen_tcp.accept(listener)
      {:ok, _request} = :gen_tcp.recv(stalled, 0)
      send(script, :stalled)
      {:ok, socket} = :gen_tcp.accept(listener)
      {:ok, _request} = :gen_tcp.recv(socket, 0)
      :ok = :gen_tcp.send(socket, "HTTP/1.1 200 OK\\r\\ncontent-length: 7\\r\\n\\r\\nproxied")
      Process.sleep(:infinity)
    end)

    Application.put_env(:kettlecorn, :release_base_url, "http://kettlecorn.test/releases")
    install = fn n -> Kettlecorn.Install.runtime([dir: #{inspect(dir)} <> "/runtime-\#{n}"], fn _ -> {:ok, "0"} end) end
    spawn(fn -> install.(1) end)
    receive do: (:stalled -> IO.inspect(install.(2)))
    """

    assert run_script(script, proxy_env(nil)) =~ "SHA-256"
  end

  defp proxy_env(http_proxy) do
    [{"MIX_ENV", "test"}, {"http_proxy", http_proxy}] ++
      for name <- ~w(HTTP_PROXY https_proxy HTTPS_PROXY no_proxy NO_PROXY), do: {name, nil}
  end

  defp run_script(script, env) do
    {output, 0} =
      System.cmd("mix", ["run", "--no-start", "-e", script],
        cd: Path.expand("..", __DIR__),
        env: env,
        stderr_to_stdout: true
      )

    output
  end

  defp start_redirect(location),
    do: start_server("HTTP/1.1 302 Found\r\nlocation: #{location}\r\ncontent-length: 0\r\n\r\n")

  # Answers one request with `reply`.
  defp start_server(reply) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false, reuseaddr: true])

    {:ok, port} = :inet.port(listener)

    spawn_link(fn ->
      {:ok, socket} = :gen_tcp.accept(listener)
      {:ok, _request} = :gen_tcp.recv(socket, 0, 10_000)
      :ok = :gen_tcp.send(socket, reply)
      :gen_tcp.close(socket)
    end)

    port
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
