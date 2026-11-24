defmodule Kettlecorn.LauncherTest do
  use ExUnit.Case, async: false
  alias Kettlecorn.Sandbox
  alias Kettlecorn.Sandbox.Instance
  @moduletag :integration
  @moduletag :tmp_dir

  test "termination outcomes are independent of retained stderr" do
    for {options, code, reason, diagnostics} <- [
          {[], "System.halt(0)", :normal, "wasm trap: interrupt; all fuel consumed"},
          {[], "System.halt(23)", {:exit_status, 23}, "wasm trap: interrupt"},
          {[max_fuel: 3_000_000_000], "Stream.repeatedly(fn -> 1 end) |> Stream.run()",
           :out_of_fuel, :binary.copy("x", 8192)},
          {[max_lifetime: 10_000], "Process.sleep(:infinity)", :timeout, :binary.copy("x", 8192)}
        ] do
      {:ok, vm} = Kettlecorn.start(TestRuntime.opts(options))
      on_exit(fn -> Kettlecorn.stop(vm) end)
      monitor = Process.monitor(vm)
      instance = :sys.get_state(vm).instance
      stderr = Instance.stderr_file(instance)

      assert {:ok, _} =
               Kettlecorn.eval(vm, "spawn(fn -> Process.sleep(100); #{code} end)")

      :ok = :sys.suspend(vm)

      try do
        await_stopped(stderr <> ".stopped", System.monotonic_time(:millisecond) + 20_000)
        File.write!(stderr, diagnostics)
      after
        :ok = :sys.resume(vm)
      end

      assert_receive {:DOWN, ^monitor, :process, ^vm, {:shutdown, {:vm_down, actual}}}, 5_000

      case reason do
        {:exit_status, status} -> assert actual == {:exit_status, status, diagnostics}
        _ -> assert actual == reason
      end
    end
  end

  test "guest output stays bounded before a suspended VM can process it" do
    for owner <- [nil, self()] do
      {:ok, vm} = Kettlecorn.start(TestRuntime.opts(owner: owner, output_limit: 0))
      on_exit(fn -> Kettlecorn.stop(vm) end)

      assert {:ok, _} =
               Kettlecorn.eval(vm, """
               spawn(fn ->
                 Process.sleep(100)
                 chunk = :binary.copy("x", 65_536)
                 for _ <- 1..128, do: IO.binwrite(:user, chunk)
               end)
               """)

      :ok = :sys.suspend(vm)

      try do
        Process.sleep(500)
        {:messages, messages} = Process.info(vm, :messages)

        bytes =
          Enum.reduce(messages, 0, fn
            {_port, {:data, data}}, total -> total + byte_size(data)
            {:tcp, _socket, data}, total -> total + byte_size(data)
            _message, total -> total
          end)

        assert bytes in 1..65_536, "queued #{bytes} raw guest bytes with owner #{inspect(owner)}"
      after
        :ok = :sys.resume(vm)
      end

      assert {:ok, %{"value" => 2}} = Kettlecorn.eval(vm, "1 + 1")
      output_dir = :sys.get_state(vm).output_transport.dir
      assert :ok = Kettlecorn.stop(vm)
      refute File.exists?(output_dir)
    end
  end

  test "abrupt launcher death uses the exit status without interpreting stderr" do
    {:ok, vm} = Kettlecorn.start(TestRuntime.opts())
    on_exit(fn -> Kettlecorn.stop(vm) end)
    monitor = Process.monitor(vm)
    state = :sys.get_state(vm)
    diagnostics = "wasm trap: interrupt; all fuel consumed"
    File.write!(Instance.stderr_file(state.instance), diagnostics)
    {:os_pid, pid} = Port.info(state.port, :os_pid)
    {_, 0} = System.cmd("kill", ["-KILL", to_string(pid)])

    assert_receive {:DOWN, ^monitor, :process, ^vm,
                    {:shutdown, {:vm_down, {:exit_status, 137, ^diagnostics}}}},
                   5_000
  end

  test "drains output before reporting the launcher exit" do
    {:ok, vm} = Kettlecorn.start(TestRuntime.opts(owner: self(), output_limit: 0))
    on_exit(fn -> Kettlecorn.stop(vm) end)
    monitor = Process.monitor(vm)

    assert {:error, {:vm_down, :normal}} =
             Kettlecorn.eval(
               vm,
               ~s|IO.binwrite(:user, :binary.copy("x", 524_288)); System.halt(0)|
             )

    assert collect_output(vm, monitor, []) == :binary.copy("x", 524_288)
  end

  defp collect_output(vm, monitor, chunks) do
    receive do
      {:kettlecorn, ^vm, {:stdout, data}} ->
        collect_output(vm, monitor, [data | chunks])

      {:DOWN, ^monitor, :process, ^vm, _reason} ->
        chunks |> Enum.reverse() |> IO.iodata_to_binary()
    after
      5_000 -> flunk("VM did not stop after draining output")
    end
  end

  test "closing the port during a cold boot stops the launcher promptly", %{tmp_dir: tmp} do
    for input <- [<<>>, <<1024::32, "pending">>] do
      instance =
        TestRuntime.opts(
          instances_dir: Path.join(tmp, "instances"),
          cache_dir: Path.join(tmp, "cold-cache")
        )
        |> Sandbox.new()
        |> Instance.prepare()

      marker = Instance.stderr_file(instance) <> ".stopped"
      on_exit(fn -> if File.regular?(marker), do: Instance.cleanup(instance) end)
      [executable | args] = Instance.command(instance)

      port =
        Port.open({:spawn_executable, executable}, [:binary, :exit_status, :use_stdio, args: args])

      :erlang.unlink(port)
      assert Port.command(port, input)
      started = System.monotonic_time(:millisecond)
      :erlang.exit(port, :kill)
      await_stopped(marker, started + 2000)
      # Cancelled before the guest started: no memory yet, and no fuel without --fuel.
      assert JSON.decode!(File.read!(marker)) == %{"outcome" => "cancelled", "memory" => 0}
      Instance.cleanup(instance)
      assert File.ls!(Path.join(tmp, "instances")) == []
    end
  end

  defp await_stopped(marker, deadline) do
    unless File.regular?(marker) do
      assert System.monotonic_time(:millisecond) < deadline,
             "launcher did not stop after port closure"

      Process.sleep(10)
      await_stopped(marker, deadline)
    end
  end

  test "boots, evaluates, performs HTTP and stops without Python or Wasmtime on PATH", %{
    tmp_dir: tmp
  } do
    path = System.fetch_env!("PATH")
    bin = Path.join(tmp, "bin")
    File.mkdir!(bin)

    System.put_env("PATH", bin)
    on_exit(fn -> System.put_env("PATH", path) end)
    assert System.find_executable("python3") == nil
    assert System.find_executable("wasmtime") == nil
    assert System.find_executable("cp") == nil
    assert System.find_executable("chmod") == nil

    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    on_exit(fn -> :gen_tcp.close(listener) end)
    {:ok, port} = :inet.port(listener)

    server =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 10_000)
        {:ok, _request} = :gen_tcp.recv(socket, 0, 10_000)

        :ok =
          :gen_tcp.send(
            socket,
            "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"
          )

        :gen_tcp.close(socket)
      end)

    instances = Path.join(tmp, "instances")
    {:ok, vm} = Kettlecorn.start(TestRuntime.opts(http: true, instances_dir: instances))
    on_exit(fn -> Kettlecorn.stop(vm) end)
    assert {:ok, %{"value" => 2}} = Kettlecorn.eval(vm, "1 + 1")

    assert {:ok, %{"value" => {:ok, %{status: 200, body: "ok"}}}} =
             Kettlecorn.eval(vm, ~s|Kettlecorn.HTTP.request(:get, "http://127.0.0.1:#{port}/")|)

    Task.await(server)
    assert :ok = Kettlecorn.stop(vm)
    assert File.ls!(instances) == []
  end
end
