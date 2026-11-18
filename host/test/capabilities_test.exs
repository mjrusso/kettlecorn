defmodule Kettlecorn.CapabilitiesTest do
  # Crypto, sockets and HTTP inside the guest. Servers run on the host
  # (this test process), on 127.0.0.1.
  use ExUnit.Case, async: true

  @moduletag :integration
  @moduletag timeout: 120_000

  defp start_vm(opts \\ []) do
    {:ok, vm} = Kettlecorn.start_link(TestRuntime.opts(opts))
    on_exit(fn -> Kettlecorn.stop(vm) end)
    vm
  end

  describe "crypto" do
    test "hashes, secure random bytes, AEAD and signatures" do
      vm = start_vm()

      code = ~S"""
      key = :crypto.strong_rand_bytes(32)
      iv = :crypto.strong_rand_bytes(12)
      {ct, tag} = :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, "secret", "", true)
      {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
      sig = :crypto.sign(:eddsa, :none, "msg", [priv, :ed25519])

      %{
        sha256: Base.encode16(:crypto.hash(:sha256, "hello"), case: :lower),
        rand: byte_size(:crypto.strong_rand_bytes(16)),
        aead: :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, ct, "", tag, false),
        ed25519: :crypto.verify(:eddsa, :none, "msg", sig, [pub, :ed25519]),
        openssl: :crypto.info_lib() |> hd() |> elem(2)
      }
      """

      assert {:ok, %{"value" => v}} = Kettlecorn.eval(vm, code)
      assert v.sha256 == "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
      assert v.rand == 16
      assert v.aead == "secret"
      assert v.ed25519 == true
      assert v.openssl =~ "OpenSSL 3."
    end
  end

  describe "sockets" do
    test "the guest's host name is localhost, with or without the network grant" do
      for grant <- [[], [network: true]] do
        vm = start_vm(grant)

        assert {:ok, %{"value" => {{:ok, ~c"localhost"}, ~c"localhost"}}} =
                 Kettlecorn.eval(vm, "{:inet.gethostname(), :inet_db.gethostname()}")
      end

      # Asked through a socket, the inet driver calls gethostname().
      vm = start_vm(network: true)
      code = "{:ok, s} = :gen_udp.open(0); :inet.gethostname(s)"
      assert {:ok, %{"value" => {:ok, ~c"localhost"}}} = Kettlecorn.eval(vm, code)
    end

    test "are denied without network: true" do
      {:ok, listener} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false])
      {:ok, port} = :inet.port(listener)
      vm = start_vm()

      assert {:ok, %{"value" => {:error, :eacces}}} =
               Kettlecorn.eval(
                 vm,
                 ":gen_tcp.connect({127, 0, 0, 1}, #{port}, [], 2000)"
               )

      assert {:ok, %{"value" => {:error, _}}} =
               Kettlecorn.eval(vm, ~S|:inet.getaddr(~c"example.com", :inet)|)
    end

    test "TCP and native name lookup with network: true" do
      {:ok, listener} =
        :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false, reuseaddr: true])

      {:ok, port} = :inet.port(listener)

      spawn_link(fn ->
        {:ok, sock} = :gen_tcp.accept(listener)
        {:ok, data} = :gen_tcp.recv(sock, 0)
        :ok = :gen_tcp.send(sock, "echo:" <> data)
      end)

      vm = start_vm(network: true)

      code = """
      {:ok, s} = :gen_tcp.connect(~c"localhost", #{port}, [:binary, active: false], 5000)
      :ok = :gen_tcp.send(s, "ping")
      {:ok, reply} = :gen_tcp.recv(s, 0, 5000)
      {:ok, {:hostent, _, _, :inet, 4, addresses}} =
        :inet_gethost_native.gethostbyname(~c"localhost", :inet)
      {:error, :notfound} = :inet_gethost_native.gethostbyaddr(~c"127.0.0.1")
      {:error, :formerr} = :inet_gethost_native.gethostbyaddr(:invalid)
      :ok = :inet_gethost_native.control(:soft_restart)
      {reply, :inet.getaddr(~c"localhost", :inet), {127, 0, 0, 1} in addresses}
      """

      assert {:ok, %{"value" => {"echo:ping", {:ok, {127, 0, 0, 1}}, true}}} =
               Kettlecorn.eval(vm, code)
    end

    test "TLS 1.3 with certificate verification, network: true" do
      %{server_config: server, client_config: client} = test_pki()

      {:ok, _} = Application.ensure_all_started(:ssl)

      {:ok, listener} =
        :ssl.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false, reuseaddr: true] ++ server)

      {:ok, {_, port}} = :ssl.sockname(listener)

      spawn_link(fn ->
        {:ok, t} = :ssl.transport_accept(listener)
        {:ok, s} = :ssl.handshake(t, 10_000)
        {:ok, data} = :ssl.recv(s, 0, 10_000)
        :ok = :ssl.send(s, "tls:" <> data)
        Process.sleep(1_000)
      end)

      cacerts = Keyword.fetch!(client, :cacerts)
      vm = start_vm(network: true)

      code = """
      {:ok, _} = Application.ensure_all_started(:ssl)
      opts = [:binary, active: false, verify: :verify_peer, cacerts: cacerts,
              server_name_indication: ~c"localhost"]
      {:ok, s} = :ssl.connect(~c"localhost", #{port}, opts, 10_000)
      {:ok, [protocol: protocol]} = :ssl.connection_information(s, [:protocol])
      :ok = :ssl.send(s, "hello")
      {:ok, reply} = :ssl.recv(s, 0, 10_000)
      {protocol, reply}
      """

      assert {:ok, %{"value" => {:"tlsv1.3", "tls:hello"}}} =
               Kettlecorn.eval(vm, code, binding: %{cacerts: cacerts}, timeout: 30_000)
    end
  end

  describe "CA certificates" do
    test "network: true passes the host's by default" do
      host =
        try do
          length(:public_key.cacerts_get())
        catch
          :error, _ -> nil
        end

      vm = start_vm(network: true)

      assert {:ok, %{"value" => ^host}} =
               Kettlecorn.eval(vm, """
               try do
                 length(:public_key.cacerts_get())
               catch
                 :error, _ -> nil
               end
               """)
    end

    @tag :tmp_dir
    test "Req verifies HTTPS against :cacerts, as DER certificates or a PEM file", %{tmp_dir: tmp} do
      %{server_config: server, client_config: client} = test_pki()
      port = start_https_server(server)
      ders = Keyword.fetch!(client, :cacerts)
      pem = Path.join(tmp, "ca.pem")

      File.write!(
        pem,
        :public_key.pem_encode(for der <- ders, do: {:Certificate, der, :not_encrypted})
      )

      code = """
      case Req.get("https://localhost:#{port}/", retry: false) do
        {:ok, response} -> {response.status, response.body}
        {:error, error} -> {:error, inspect(error.__struct__)}
      end
      """

      for cacerts <- [ders, pem] do
        vm = start_vm(network: true, cacerts: cacerts)
        assert {:ok, %{"value" => {200, "ok"}}} = Kettlecorn.eval(vm, code, timeout: 30_000)
      end

      %{client_config: other} = test_pki()
      vm = start_vm(network: true, cacerts: Keyword.fetch!(other, :cacerts))
      assert {:ok, %{"value" => {:error, _}}} = Kettlecorn.eval(vm, code, timeout: 30_000)
    end

    test "cacerts: [] leaves the guest without a trust store; a request can pass its own" do
      %{server_config: server, client_config: client} = test_pki()
      port = start_https_server(server)
      vm = start_vm(network: true, cacerts: [])

      code = """
      url = "https://localhost:#{port}/"

      {
        try do
          :public_key.cacerts_get()
        catch
          :error, _ -> :raised
        end,
        try do
          Req.get(url, retry: false)
        rescue
          _ -> :raised
        end,
        Req.get!(url, retry: false, connect_options: [transport_opts: [cacerts: cacerts]]).body
      }
      """

      assert {:ok, %{"value" => {:raised, :raised, "ok"}}} =
               Kettlecorn.eval(vm, code,
                 binding: %{cacerts: Keyword.fetch!(client, :cacerts)},
                 timeout: 30_000
               )
    end

    test "invalid :cacerts raise" do
      assert_raise ArgumentError, ~r/no PEM certificates/, fn ->
        Kettlecorn.Sandbox.new(TestRuntime.opts(network: true, cacerts: "mix.exs"))
      end

      assert_raise ArgumentError, ~r/isn't a DER certificate/, fn ->
        Kettlecorn.Sandbox.new(TestRuntime.opts(network: true, cacerts: ["not a certificate"]))
      end
    end
  end

  describe "HTTP (wasi:http)" do
    test "zero receive timeouts expire and infinite timeouts fail explicitly" do
      port = start_http_server()
      vm = start_vm(http: true)

      code = """
      url = "http://127.0.0.1:#{port}/delayed"
      for timeout <- [0, :infinity] do
        {:error, direct} = Kettlecorn.HTTP.request(:get, url, receive_timeout: timeout)
        {:error, req} = Req.get(url, receive_timeout: timeout, retry: false)
        {Atom.to_string(direct), Atom.to_string(req.reason)}
      end
      """

      assert {:ok, %{"value" => [{direct, req}, {"unsupported_timeout", "unsupported_timeout"}]}} =
               Kettlecorn.eval(vm, code)

      assert direct =~ "timeout"
      assert req =~ "timeout"
    end

    test "invalid timeout values raise through HTTP, Req, and the NIF" do
      vm = start_vm(http: true)

      code = """
      calls = [
        fn key, timeout ->
          Kettlecorn.HTTP.request(:get, "http://127.0.0.1:1/", [{key, timeout}])
        end,
        fn
          :connect_timeout, timeout ->
            Req.get("http://127.0.0.1:1/", connect_options: [timeout: timeout], retry: false)
          :receive_timeout, timeout ->
            Req.get("http://127.0.0.1:1/", receive_timeout: timeout, retry: false)
        end,
        fn key, timeout ->
          {connect, read} = if key == :connect_timeout,
            do: {timeout, :default}, else: {:default, timeout}
          :wasm.http_send("GET", :http, "127.0.0.1:1", "/", [], nil, connect, read)
        end
      ]
      for timeout <- [-1, nil, false, 1.5, :invalid, 18_446_744_073_710],
          key <- [:connect_timeout, :receive_timeout], call <- calls do
        try do
          call.(key, timeout)
          :accepted
        rescue
          ArgumentError -> :rejected
        end
      end
      """

      assert {:ok, %{"value" => values}} = Kettlecorn.eval(vm, code)
      assert values == List.duplicate(:rejected, 36)
    end

    test "connect infinity fails explicitly and large finite timeouts reach the transport" do
      vm = start_vm(http: true)

      code = """
      for timeout <- [:infinity, 18_446_744_073_709] do
        {:error, direct} = Kettlecorn.HTTP.request(:get, "http://127.0.0.1:1/",
          connect_timeout: timeout, receive_timeout: timeout)
        {:error, req} = Req.get("http://127.0.0.1:1/",
          connect_options: [timeout: timeout], receive_timeout: timeout, retry: false)
        {Atom.to_string(direct), Atom.to_string(req.reason)}
      end
      """

      assert {:ok,
              %{
                "value" => [
                  {"unsupported_timeout", "unsupported_timeout"},
                  {"connection_refused", "connection_refused"}
                ]
              }} = Kettlecorn.eval(vm, code)
    end

    test "Kettlecorn.HTTP is unavailable without http: true" do
      vm = start_vm()
      assert {:ok, %{"value" => false}} = Kettlecorn.eval(vm, "Kettlecorn.HTTP.available?()")

      assert {:ok, %{"value" => {:error, :unsupported}}} =
               Kettlecorn.eval(vm, ~S|Kettlecorn.HTTP.request(:get, "http://127.0.0.1:1/")|)
    end

    test "Kettlecorn.HTTP.request/3 and stream/5 with http: true" do
      port = start_http_server()
      vm = start_vm(http: true)
      assert {:ok, %{"value" => true}} = Kettlecorn.eval(vm, "Kettlecorn.HTTP.available?()")

      code = """
      Kettlecorn.HTTP.request(:post, "http://127.0.0.1:#{port}/echo?x=1",
        headers: [{"x-test", "yes"}],
        body: "request body"
      )
      """

      assert {:ok, %{"value" => {:ok, response}}} = Kettlecorn.eval(vm, code)
      assert response.status == 201
      assert {"x-server", "host"} in response.headers
      assert response.body == "POST /echo?x=1 yes request body"

      # Streamed: count the body's chunks and bytes without keeping it.
      big = """
      fun = fn
        {:data, d}, {n, size} -> {:cont, {n + 1, size + byte_size(d)}}
        _, acc -> {:cont, acc}
      end
      {:ok, {chunks, size}} = Kettlecorn.HTTP.stream(:get, "http://127.0.0.1:#{port}/big", {0, 0}, fun)
      {chunks > 1, size}
      """

      assert {:ok, %{"value" => {true, 300_000}}} = Kettlecorn.eval(vm, big)

      assert {:ok, %{"value" => {:error, :connection_refused}}} =
               Kettlecorn.eval(vm, ~S|Kettlecorn.HTTP.request(:get, "http://127.0.0.1:1/")|)

      assert {:ok, %{"value" => {:error, :invalid_url}}} =
               Kettlecorn.eval(vm, ~S|Kettlecorn.HTTP.request(:get, "ftp://example.com/")|)
    end

    test "malformed request headers raise before sending a request" do
      vm = start_vm(http: true)

      code = """
      for headers <- [[{"x-test", "yes"}, :invalid], [{"x-test", 1}], [{"x-test"}]] do
        try do
          :wasm.http_send("GET", :http, "127.0.0.1:1", "/", headers, nil, 0, 0)
        rescue
          ArgumentError -> :badarg
        end
      end
      """

      assert {:ok, %{"value" => [:badarg, :badarg, :badarg]}} = Kettlecorn.eval(vm, code)

      assert {:ok, %{"value" => {:error, :invalid_header}}} =
               Kettlecorn.eval(
                 vm,
                 ~S|:wasm.http_send("GET", :http, "127.0.0.1:1", "/", [{<<0>>, "yes"}], nil, 0, 0)|
               )
    end

    test "HTTP response headers preserve repeated names and empty values" do
      port = start_http_server()
      vm = start_vm(http: true)
      code = ~s|Kettlecorn.HTTP.request(:get, "http://127.0.0.1:#{port}/headers")|

      assert {:ok, %{"value" => {:ok, response}}} = Kettlecorn.eval(vm, code)
      assert response.status == 200
      assert response.body == ""
      assert {"x-empty", ""} in response.headers

      assert Enum.filter(response.headers, fn {name, _} -> name == "set-cookie" end) ==
               [{"set-cookie", "a=1"}, {"set-cookie", "b=2"}]
    end

    test "a body cut short and a stalled response are errors, not short bodies" do
      port = start_http_server()
      vm = start_vm(http: true)

      # The reasons are wasi:http error codes, atoms the host may not have:
      # the guest returns them as strings.
      request = fn path, opts ->
        url = "http://127.0.0.1:#{port}#{path}"
        ~s|{:error, r} = Kettlecorn.HTTP.request(:get, "#{url}", #{opts}); Atom.to_string(r)|
      end

      # The server closes the connection 10 bytes into a 1000-byte body.
      assert {:ok, %{"value" => reason}} = Kettlecorn.eval(vm, request.("/truncated", "[]"))
      assert reason in ~w(http_protocol_error http_response_incomplete connection_terminated)

      # stream/5 returns the accumulator so far with the error.
      code = """
      fun = fn {:data, d}, acc -> {:cont, acc <> d}; _, acc -> {:cont, acc} end
      Kettlecorn.HTTP.stream(:get, "http://127.0.0.1:#{port}/truncated", "", fun)
      """

      assert {:ok, %{"value" => {:error, _, "0123456789"}}} = Kettlecorn.eval(vm, code)

      # The server sends the head and 10 bytes, then nothing for 5 seconds.
      started = System.monotonic_time(:millisecond)
      opts = "receive_timeout: 500"
      assert {:ok, %{"value" => reason}} = Kettlecorn.eval(vm, request.("/slow", opts))
      assert reason =~ "timeout"
      assert System.monotonic_time(:millisecond) - started < 4_000
    end
  end

  describe "Req" do
    test "uses Kettlecorn.HTTP (wasi:http) by default when both grants are enabled" do
      port = start_http_server()
      vm = start_vm(network: true, http: true)

      code = """
      {:ok, _} = Application.ensure_all_started(:req)
      r = Req.post!("http://127.0.0.1:#{port}/req", body: "via req", headers: [x_test: "yes"])
      {inspect(Req.default_options()[:adapter]), r.status, r.body, Req.Response.get_header(r, "x-server")}
      """

      assert {:ok,
              %{"value" => {"Kettlecorn.HTTP.ReqAdapter", 201, "POST /req yes via req", ["host"]}}} =
               Kettlecorn.eval(vm, code)

      # into: a function (streaming) and a collectable
      streamed = """
      fun = fn {:data, d}, {req, resp} -> {:cont, {req, update_in(resp.private[:n], &((&1 || 0) + byte_size(d)))}} end
      r = Req.get!("http://127.0.0.1:#{port}/big", into: fun)
      {r.status, r.private[:n], byte_size(Req.get!("http://127.0.0.1:#{port}/big", into: "").body)}
      """

      assert {:ok, %{"value" => {201, 300_000, 300_000}}} = Kettlecorn.eval(vm, streamed)

      assert {:ok, %{"value" => errors}} =
               Kettlecorn.eval(vm, """
               for into <- [nil, "", fn _, acc -> {:cont, acc} end] do
                 {:error, e} = Req.get("http://127.0.0.1:1/", into: into, retry: false)
                 {inspect(e.__struct__), e.reason}
               end
               """)

      assert errors == List.duplicate({"Req.TransportError", :connection_refused}, 3)
    end

    test "collectable resources close on success, transport errors, and exceptional exits" do
      port = start_http_server()
      vm = start_vm(http: true)

      code = """
      defmodule ResourceSink do
        defstruct [:device, :owner, failures: %{}]
      end

      defimpl Collectable, for: ResourceSink do
        def into(sink) do
          {sink.device, fn device, command ->
            tag = case command do
              {:cont, _data} -> :cont
              terminal -> terminal
            end
            send(sink.owner, {:sink_command, tag})
            if tag == :halt, do: File.close(device)

            message = if tag == :halt, do: "cleanup failed", else: "sink failed"
            case sink.failures[tag] do
              :raise -> raise message
              :throw -> throw(message)
              :exit -> exit(message)
              nil -> :ok
            end

            case command do
              {:cont, data} -> :ok = IO.binwrite(device, data); device
              :done -> File.close(device); sink
              :halt -> :ok
            end
          end}
        end
      end

      commands = fn commands, acc ->
        receive do
          {:sink_command, command} -> commands.(commands, [command | acc])
        after
          0 -> acc
        end
      end

      for {path, failures} <- [
        {"/req", %{cont: :raise}},
        {"/req", %{cont: :throw}},
        {"/req", %{cont: :exit}},
        {"/req", %{done: :raise}},
        {"/req", %{cont: :raise, halt: :raise}},
        {"/req", %{}},
        {"/truncated", %{}},
        {"/truncated", %{halt: :raise}}
      ] do
        device = File.open!("/tmp/collector", [:write])
        sink = struct(ResourceSink, device: device, owner: self(), failures: failures)
        result = try do
          case Req.get("http://127.0.0.1:#{port}" <> path, into: sink, retry: false) do
            {:ok, response} -> {:ok, response.status}
            {:error, error} -> {:transport_error, inspect(error.__struct__)}
          end
        catch
          kind, reason ->
            [{origin, _, _, _} | _] = __STACKTRACE__
            message = if is_exception(reason), do: Exception.message(reason), else: reason
            {kind, message, origin == Collectable.ResourceSink}
        end

        seen = commands.(commands, [])
        closed = match?({:error, :terminated}, :file.write(device, "after collection"))
        File.close(device)
        {result, Enum.count(seen, &(&1 == :done)), Enum.count(seen, &(&1 == :halt)), closed}
      end
      """

      assert {:ok, %{"value" => results}} = Kettlecorn.eval(vm, code, timeout: 30_000)

      assert results == [
               {{:error, "sink failed", true}, 0, 1, true},
               {{:throw, "sink failed", true}, 0, 1, true},
               {{:exit, "sink failed", true}, 0, 1, true},
               {{:error, "sink failed", true}, 1, 1, true},
               {{:error, "sink failed", true}, 0, 1, true},
               {{:ok, 201}, 1, 0, true},
               {{:transport_error, "Req.TransportError"}, 0, 1, true},
               {{:error, "cleanup failed", true}, 0, 1, true}
             ]
    end

    test "leaves Req's default adapter unchanged with network: true" do
      port = start_http_server()
      vm = start_vm(network: true)

      code = """
      {:ok, _} = Application.ensure_all_started(:req)
      r = Req.get!("http://localhost:#{port}/finch", retry: false)
      {Req.default_options()[:adapter], r.status, r.body}
      """

      assert {:ok, %{"value" => {nil, 201, "GET /finch  "}}} = Kettlecorn.eval(vm, code)
    end

    test "HTTP and HTTPS report disabled networking before transport setup" do
      vm = start_vm()

      code = """
      for scheme <- ["http", "https"] do
        url = scheme <> "://example.test/"
        {:error, error} = Req.get(url, retry_delay: fn _ -> raise "permission error retried" end)

        raised = try do
          Req.get!(url)
        rescue
          exception -> {inspect(exception.__struct__), Exception.message(exception)}
        end

        {inspect(error.__struct__), to_string(error.reason), Exception.message(error), raised}
      end
      """

      assert {:ok, %{"value" => results}} = Kettlecorn.eval(vm, code)

      for {type, reason, message, raised} <- results do
        assert type == "Kettlecorn.NetworkDisabledError"
        assert reason == "network_disabled"
        assert message =~ "Outgoing HTTP is disabled"
        assert message =~ "--http (http: true)"
        assert message =~ "--network (network: true)"
        assert raised == {type, message}
      end
    end

    @tag :tmp_dir
    test "configured adapters are preserved with and without grants", %{tmp_dir: tmp} do
      app = Path.join(tmp, "app")
      config = Path.join(tmp, "config.exs")
      build = Path.join(tmp, "build")
      ebin = Path.join([build, "configured", "ebin"])
      File.mkdir_p!(ebin)

      File.write!(
        Path.join(ebin, "configured.app"),
        ~s|{application, configured, [{applications, [kernel, stdlib]}, {modules, []}, {vsn, "0.1.0"}]}.\n|
      )

      File.write!(
        config,
        "import Config\nconfig :req, default_options: [adapter: OfflineAdapter]\n"
      )

      assert {:ok, _} =
               Kettlecorn.Cook.cook(
                 app: :configured,
                 build: build,
                 out: app,
                 config: config,
                 runtime: TestRuntime.runtime()
               )

      code = """
      defmodule OfflineAdapter do
        def run(request), do: {request, Req.Response.new(status: 200, body: "configured")}
      end

      Req.get!("https://example.test/").body
      """

      for grants <- [[], [network: true, http: true]] do
        vm = start_vm([app: app] ++ grants)
        assert {:ok, %{"value" => "configured"}} = Kettlecorn.eval(vm, code)
      end
    end
  end

  defp test_pki do
    :public_key.pkix_test_data(%{
      server_chain: %{
        root: [key: {:rsa, 2048, 65_537}],
        peer: [
          key: {:rsa, 2048, 65_537},
          extensions: [{:Extension, {2, 5, 29, 17}, false, [dNSName: ~c"localhost"]}]
        ]
      },
      client_chain: %{root: [key: {:rsa, 2048, 65_537}], peer: [key: {:rsa, 2048, 65_537}]}
    })
  end

  defp start_https_server(config) do
    {:ok, _} = Application.ensure_all_started(:ssl)

    {:ok, listener} =
      :ssl.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false, reuseaddr: true] ++ config)

    {:ok, {_, port}} = :ssl.sockname(listener)
    spawn_link(fn -> https_accept_loop(listener) end)
    port
  end

  defp https_accept_loop(listener) do
    {:ok, socket} = :ssl.transport_accept(listener)

    spawn(fn ->
      with {:ok, socket} <- :ssl.handshake(socket, 10_000),
           {:ok, _request} <- :ssl.recv(socket, 0, 10_000) do
        :ssl.send(socket, "HTTP/1.1 200 OK\r\ncontent-length: 2\r\nconnection: close\r\n\r\nok")
        :ssl.close(socket)
      end
    end)

    https_accept_loop(listener)
  end

  # A minimal HTTP/1.1 server: answers "<method> <path> <x-test> <body>", or
  # 300 kB for /big, then closes the connection. /truncated and /slow
  # misbehave (see serve/2).
  defp start_http_server do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false, reuseaddr: true])

    {:ok, port} = :inet.port(listener)
    spawn_link(fn -> accept_loop(listener) end)
    port
  end

  defp accept_loop(listener) do
    {:ok, sock} = :gen_tcp.accept(listener)
    spawn(fn -> serve(sock) end)
    accept_loop(listener)
  end

  defp serve(sock) do
    {method, path, headers, body} = read_request(sock, "")
    serve(sock, {method, path, headers, body})
    :gen_tcp.close(sock)
  end

  # 10 bytes of a 1000-byte body, then the connection closes.
  defp serve(sock, {_, "/truncated", _, _}) do
    head = "HTTP/1.1 200 OK\r\ncontent-length: 1000\r\nconnection: close\r\n\r\n"
    :gen_tcp.send(sock, [head, "0123456789"])
  end

  # The head and part of the body, then nothing for a while.
  defp serve(sock, {_, "/slow", _, _}) do
    head = "HTTP/1.1 200 OK\r\ncontent-length: 1000\r\nconnection: close\r\n\r\n"
    :gen_tcp.send(sock, [head, "0123456789"])
    Process.sleep(5_000)
  end

  defp serve(sock, {_, "/headers", _, _}) do
    :gen_tcp.send(sock, [
      "HTTP/1.1 200 OK\r\nset-cookie: a=1\r\nset-cookie: b=2\r\nx-empty:\r\n",
      "content-length: 0\r\nconnection: close\r\n\r\n"
    ])
  end

  defp serve(sock, {_, "/delayed", _, _}) do
    Process.sleep(200)
    :gen_tcp.send(sock, "HTTP/1.1 200 OK\r\ncontent-length: 2\r\nconnection: close\r\n\r\nok")
  end

  defp serve(sock, {method, path, headers, body}) do
    reply =
      if path == "/big",
        do: :binary.copy("x", 300_000),
        else: "#{method} #{path} #{headers["x-test"]} #{body}"

    :gen_tcp.send(sock, [
      "HTTP/1.1 201 Created\r\ncontent-type: text/plain\r\nx-server: host\r\n",
      "content-length: #{byte_size(reply)}\r\nconnection: close\r\n\r\n",
      reply
    ])
  end

  defp read_request(sock, acc) do
    case String.split(acc, "\r\n\r\n", parts: 2) do
      [head, rest] ->
        [request_line | header_lines] = String.split(head, "\r\n")
        [method, path, _] = String.split(request_line, " ")

        headers =
          Map.new(header_lines, fn line ->
            [k, v] = String.split(line, ":", parts: 2)
            {String.downcase(k), String.trim(v)}
          end)

        length = String.to_integer(Map.get(headers, "content-length", "0"))
        {method, path, headers, read_body(sock, rest, length)}

      [_] ->
        {:ok, data} = :gen_tcp.recv(sock, 0, 10_000)
        read_request(sock, acc <> data)
    end
  end

  defp read_body(_sock, body, length) when byte_size(body) >= length, do: body

  defp read_body(sock, body, length) do
    {:ok, data} = :gen_tcp.recv(sock, 0, 10_000)
    read_body(sock, body <> data, length)
  end
end
