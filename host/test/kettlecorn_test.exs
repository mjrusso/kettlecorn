defmodule KettlecornTest do
  # Each test boots real VMs in the launcher, see test_helper.exs.
  use ExUnit.Case, async: true

  @moduletag :integration
  @moduletag timeout: 120_000

  setup do
    {:ok, vm} = Kettlecorn.start_link(TestRuntime.opts(owner: self()))
    on_exit(fn -> Kettlecorn.stop(vm) end)
    %{vm: vm}
  end

  describe "eval/3" do
    test "guest application version matches the runtime manifest", %{vm: vm} do
      version = Kettlecorn.Runtime.load!(TestRuntime.runtime()).manifest.kettlecorn

      assert {:ok, %{"value" => ^version}} =
               Kettlecorn.eval(vm, "Application.spec(:kettlecorn_guest, :vsn) |> to_string()")
    end

    test "rejects malformed evaluator requests with string keys", %{vm: vm} do
      for request <- [
            :invalid,
            {:eval, "1", %{"timeout_ms" => 1000, "finish_timeout_ms" => 1000}},
            {:eval, "1", %{"timeout_ms" => 1000, "language" => "elixir"}},
            {:eval, "1",
             %{"timeout_ms" => 1000, "finish_timeout_ms" => 1000, "language" => "unknown"}}
          ] do
        assert {:ok, {:error, %{"kind" => "badarg"}}} =
                 Kettlecorn.call(vm, "kettlecorn_evaluator", request)
      end
    end

    test "returns values, inspected results and output", %{vm: vm} do
      assert {:ok, %{"value" => 3, "inspected" => "3", "output" => ""}} =
               Kettlecorn.eval(vm, "1 + 2")

      assert {:ok, %{"value" => [1, 4, 9], "output" => "hi\n"}} =
               Kettlecorn.eval(vm, ~S|IO.puts("hi"); Enum.map(1..3, &(&1 * &1))|)
    end

    test "runs real OTP/Elixir: processes, ETS, regex, bitstrings, protocols", %{vm: vm} do
      code = ~S"""
      task = Task.async(fn -> :erlang.system_info(:system_architecture) end)
      t = :ets.new(:t, [:set])
      :ets.insert(t, {:k, 42})
      [{:k, v}] = :ets.lookup(t, :k)
      <<a::4, b::4>> = <<0xAB>>
      {Task.await(task), v, Regex.run(~r/(\d+)-(\d+)/, "10-20"), {a, b}, Enum.into([x: 1], %{})}
      """

      assert {:ok, %{"value" => value}} = Kettlecorn.eval(vm, code)
      assert {~c"wasm32-unknown-wasi", 42, ["10-20", "10", "20"], {10, 11}, %{x: 1}} = value
    end

    test "defines modules and keeps state between evaluations", %{vm: vm} do
      assert {:ok, _} =
               Kettlecorn.eval(vm, """
               defmodule Greeter do
                 def hello(name), do: "Hello, \#{name}!"
               end
               """)

      assert {:ok, %{"value" => "Hello, wasm!"}} = Kettlecorn.eval(vm, ~S|Greeter.hello("wasm")|)
    end

    test "the emulator flags reach the VM", %{vm: vm} do
      code =
        "{:erlang.system_info(:schedulers), :erlang.system_info(:dirty_io_schedulers), :init.get_plain_arguments()}"

      assert {:ok, %{"value" => {1, 1, []}}} = Kettlecorn.eval(vm, code)
    end

    test "passes bindings", %{vm: vm} do
      assert {:ok, %{"value" => 42}} = Kettlecorn.eval(vm, "x * y", binding: %{x: 6, y: 7})
    end

    test "reports exceptions, throws and exits", %{vm: vm} do
      assert {:error, %{"kind" => "error", "message" => msg}} =
               Kettlecorn.eval(vm, ~S|raise "boom"|)

      assert msg =~ "(RuntimeError) boom"
      assert {:error, %{"kind" => "throw"}} = Kettlecorn.eval(vm, "throw(:ball)")
      assert {:error, %{"kind" => "exit"}} = Kettlecorn.eval(vm, "exit(:bye)")
      assert {:error, %{"kind" => "error", "message" => msg}} = Kettlecorn.eval(vm, "1 +")
      assert msg =~ "SyntaxError" or msg =~ "TokenMissingError"
    end

    test "kills evaluations that exceed their timeout; the VM survives", %{vm: vm} do
      assert {:error, %{"kind" => "timeout", "output" => "start\n"}} =
               Kettlecorn.eval(
                 vm,
                 ~S'IO.puts("start"); Stream.repeatedly(fn -> 1 end) |> Stream.run()',
                 timeout: 500
               )

      assert {:ok, %{"value" => :still_alive}} = Kettlecorn.eval(vm, ":still_alive")
    end

    test "a suspended output capture finishes before the proxy times out", %{vm: vm} do
      code = ~S"""
      leader = Process.group_leader()
      {:tracer, tracker} = :erlang.trace_info(self(), :tracer)
      [coordinator] = elem(Process.info(self(), :monitored_by), 1)
      Process.register(leader, :capture_leader)
      Process.register(tracker, :capture_tracker)
      Process.register(coordinator, :capture_coordinator)
      parent = self()
      spawn(fn ->
        Process.register(self(), :capture_child)
        :erlang.suspend_process(leader)
        send(parent, :suspended)
        Process.sleep(:infinity)
      end)
      receive do: (:suspended -> :finished)
      """

      assert {:ok, %{"value" => :finished, "output" => ""}} =
               Kettlecorn.eval(vm, code, timeout: 2_000)

      for name <- [:capture_leader, :capture_tracker, :capture_coordinator, :capture_child],
          do: assert_guest_exit(vm, name)
    end

    test "a suspended tracker cannot block completion or leave the coordinator behind", %{vm: vm} do
      for outcome <- ["Process.sleep(:infinity)", ":finished"] do
        code = """
        {:tracer, tracker} = :erlang.trace_info(self(), :tracer)
        Process.register(tracker, :capture_tracker)
        [coordinator] = elem(Process.info(self(), :monitored_by), 1)
        Process.register(coordinator, :capture_coordinator)
        parent = self()
        spawn(fn ->
          Process.register(self(), :capture_suspender)
          :erlang.suspend_process(tracker)
          send(parent, :suspended)
          Process.sleep(:infinity)
        end)
        receive do: (:suspended -> #{outcome})
        """

        result = Kettlecorn.eval(vm, code, timeout: 500)

        if outcome == ":finished" do
          assert {:ok, %{"value" => :finished}} = result
        else
          assert {:error, %{"kind" => "timeout", "message" => "evaluation timed out"}} = result
        end

        for name <- [:capture_tracker, :capture_coordinator], do: assert_guest_exit(vm, name)

        assert {:ok, _} =
                 Kettlecorn.eval(vm, "Process.exit(Process.whereis(:capture_suspender), :kill)")
      end
    end

    test "losing a forwarding leader tears down its tracker and descendants", %{vm: vm} do
      code = ~S"""
      Process.register(Process.group_leader(), :capture_leader)
      {:tracer, tracker} = :erlang.trace_info(self(), :tracer)
      Process.register(tracker, :capture_tracker)
      [coordinator] = elem(Process.info(self(), :monitored_by), 1)
      Process.register(coordinator, :capture_coordinator)
      parent = self()
      spawn(fn ->
        Process.register(self(), :capture_child)
        send(parent, :ready)
        Process.sleep(:infinity)
      end)
      receive do: (:ready -> :ok)
      """

      assert {:ok, _} = Kettlecorn.eval(vm, code)

      assert {:ok, _} =
               Kettlecorn.eval(vm, "Process.exit(Process.whereis(:capture_leader), :kill)")

      for name <- [:capture_tracker, :capture_coordinator, :capture_child],
          do: assert_guest_exit(vm, name)
    end

    test "a timed-out evaluation's processes die with it; others keep running", %{vm: vm} do
      runaway = ~S"""
      spawn(fn -> Process.register(self(), :runaway_child); Process.sleep(:infinity) end)
      Process.sleep(:infinity)
      """

      assert {:error, %{"kind" => "timeout"}} = Kettlecorn.eval(vm, runaway, timeout: 500)
      assert_guest_exit(vm, :runaway_child)

      # A process started by a finished evaluation outlives it; its output
      # goes to the VM's stdout (the owner), not to the closed capture.
      code = ~S"""
      spawn(fn ->
        Process.register(self(), :survivor)
        receive do: (:speak -> IO.puts("survivor speaks"))
      end)
      :ok
      """

      assert {:ok, %{"value" => :ok}} = Kettlecorn.eval(vm, code)
      assert {:ok, _} = Kettlecorn.eval(vm, "send(:survivor, :speak)")
      assert_receive {:kettlecorn, ^vm, {:stdout, "survivor speaks\n"}}, 5_000
    end

    test "a started process keeps its output when other processes exit meanwhile", %{vm: vm} do
      {:ok, _} =
        Kettlecorn.eval(
          vm,
          ~S|Process.register(spawn(fn -> receive do: (:stop -> :ok) end), :helper)|
        )

      code = ~S"""
      spawn(fn ->
        Process.register(self(), :survivor)
        receive do: (:speak -> IO.puts("still here"))
      end)
      ref = Process.monitor(:helper)
      send(:helper, :stop)
      receive do: ({:DOWN, ^ref, _, _, _} -> :ok)
      """

      assert {:ok, %{"value" => :ok}} = Kettlecorn.eval(vm, code)
      assert {:ok, _} = Kettlecorn.eval(vm, "send(:survivor, :speak)")
      assert_receive {:kettlecorn, ^vm, {:stdout, "still here\n"}}, 5_000
    end

    test "a forwarding coordinator releases its completed result and bindings", %{vm: vm} do
      code = ~S"""
      [coordinator] = elem(Process.info(self(), :monitored_by), 1)
      Process.register(coordinator, :idle_coordinator)
      parent = self()
      spawn(fn ->
        Process.register(self(), :memory_survivor)
        send(parent, :ready)
        receive do: (:stop -> :ok)
      end)
      receive do: (:ready -> :ok)
      :binary.copy("r", 1_000_000)
      """

      assert {:ok, %{"value" => result}} =
               Kettlecorn.eval(vm, code,
                 binding: %{payload: :binary.copy("b", 1_000_000)},
                 timeout: 10_000
               )

      assert byte_size(result) == 1_000_000

      assert {:ok, %{"value" => retained}} =
               Kettlecorn.eval(vm, """
               coordinator = Process.whereis(:idle_coordinator)
               wait = fn wait ->
                 case Process.info(coordinator, :status) do
                   {:status, :waiting} -> :ok
                   _ -> Process.sleep(1); wait.(wait)
                 end
               end
               wait.(wait)
               {:binary, binaries} = Process.info(coordinator, :binary)
               Enum.sum(for {_, size, _} <- binaries, do: size)
               """)

      assert retained < 262_144
      assert {:ok, _} = Kettlecorn.eval(vm, "send(:memory_survivor, :stop)")
      assert_guest_exit(vm, :idle_coordinator)
    end

    test "an evaluation's capture exits with the last process it started", %{vm: vm} do
      start = ~S|Process.register(spawn(fn -> receive do: (:stop -> :ok) end), :lingering)|
      assert {:ok, _} = Kettlecorn.eval(vm, start)
      {:ok, %{"value" => before}} = Kettlecorn.eval(vm, ":erlang.system_info(:process_count)")

      code = ~S"""
      ref = Process.monitor(:lingering)
      send(:lingering, :stop)
      receive do: ({:DOWN, ^ref, _, _, _} -> :ok)
      Process.sleep(100)
      :erlang.system_info(:process_count)
      """

      assert {:ok, %{"value" => count}} = Kettlecorn.eval(vm, code)
      assert count == before - 4
    end

    test "an evaluation that starts no processes leaves none behind", %{vm: vm} do
      count = "Process.sleep(100); :erlang.system_info(:process_count)"
      {:ok, %{"value" => before}} = Kettlecorn.eval(vm, count)
      for _ <- 1..50, do: assert({:ok, %{"value" => 1}} = Kettlecorn.eval(vm, "1"))
      assert {:ok, %{"value" => ^before}} = Kettlecorn.eval(vm, count)

      code = "Process.exit(Process.group_leader(), :kill); :ok"
      assert {:ok, %{"value" => :ok, "output" => ""}} = Kettlecorn.eval(vm, code)
      assert {:ok, %{"value" => ^before}} = Kettlecorn.eval(vm, count)
    end

    test "captured output is capped", %{vm: vm} do
      code = ~S"""
      IO.write(String.duplicate("é", 4_000_000))
      leader = Process.group_leader()
      # Wait for the write's handler to finish before measuring retained binaries.
      :io.getopts(leader)
      :erlang.garbage_collect(leader)
      {:binary, binaries} = Process.info(leader, :binary)
      Enum.sum(for {_, size, _} <- binaries, do: size)
      """

      assert {:ok, %{"value" => retained, "output" => output, "output_truncated" => true}} =
               Kettlecorn.eval(vm, code, timeout: 30_000)

      assert byte_size(output) <= 1_000_000 and String.valid?(output)
      assert retained < 1_100_000
    end

    test "output beyond the cap isn't kept, so it can't exhaust the VM's memory" do
      {:ok, vm} = Kettlecorn.start_link(TestRuntime.opts(max_memory: 128 * 1024 * 1024))
      on_exit(fn -> Kettlecorn.stop(vm) end)
      # 300 MB of output.
      code =
        ~S|chunk = String.duplicate("x", 100_000); for _ <- 1..3_000, do: IO.write(chunk); :done|

      assert {:ok, %{"value" => :done, "output" => output, "output_truncated" => true}} =
               Kettlecorn.eval(vm, code, timeout: 60_000)

      assert byte_size(output) == 1_000_000
    end

    test "once the output is full, further writes keep nothing", %{vm: vm} do
      # The group leader's memory after 100,000 small and empty writes past
      # the cap: each one kept would take a list cell.
      code = ~S"""
      IO.write(String.duplicate("x", 1_000_000))
      for i <- 1..100_000, do: IO.write(if(rem(i, 2) == 0, do: "y", else: ""))
      :erlang.garbage_collect(Process.group_leader())
      {:memory, memory} = Process.info(Process.group_leader(), :memory)
      memory
      """

      assert {:ok, %{"value" => memory, "output_truncated" => true}} =
               Kettlecorn.eval(vm, code, timeout: 60_000)

      assert memory < 200_000
    end

    test "an evaluation killed with any reason gets an answer", %{vm: vm} do
      # Formatting this reason as an exception would never return.
      code = ~S"""
      defmodule Stuck do
        defexception [:x]
        def message(_), do: Process.sleep(:infinity)
      end

      evaluation = self()
      spawn(fn -> Process.exit(evaluation, {Stuck.exception(x: 1), []}) end)
      Process.sleep(:infinity)
      """

      assert {:error, %{"kind" => "exit", "message" => "the evaluation exited: " <> reason}} =
               Kettlecorn.eval(vm, code, timeout: 10_000)

      assert reason =~ "Stuck"
    end

    test "IO requests that run guest code can't keep a timed-out evaluation alive", %{vm: vm} do
      # The group leader applies {M, F, A} output in a worker, which the
      # timeout kills: here a sleeping request, and ~Kp's key comparator.
      for code <- [
            ":io.request(Process.group_leader(), {:put_chars, :unicode, Process, :sleep, [:infinity]})",
            ~S|:io.format(~c"~Kp~n", [fn _, _ -> Process.sleep(:infinity) end, %{a: 1, b: 2}])|
          ] do
        assert {:error, %{"kind" => "timeout"}} = Kettlecorn.eval(vm, code, timeout: 500)
      end

      assert {:ok, %{"output" => "42\nhello"}} =
               Kettlecorn.eval(vm, ~S|:io.format("~p~n", [42]); :io.write(:hello)|)

      # A batch is parsed in linear time: 100,000 empty writes don't keep the
      # leader busy past the timeout.
      batch = ~S"""
      gl = Process.group_leader()
      :io.request(gl, {:requests, List.duplicate({:put_chars, :unicode, ""}, 100_000) ++ [{:put_chars, :unicode, "end"}]})
      """

      assert {:ok, %{"value" => :ok, "output" => "end"}} =
               Kettlecorn.eval(vm, batch, timeout: 5_000)
    end

    test "a formatting worker's result can't be forged", %{vm: vm} do
      # Guest code called by an {M, F, A} request exits with reasons shaped
      # like the worker's result: a stream that would block the leader, a
      # malformed list.
      code = ~S"""
      request = fn reason -> :io.request(Process.group_leader(), {:put_chars, :unicode, :erlang, :exit, [reason]}) end
      forged = [
        request.({:output, {:ok, Stream.repeatedly(fn -> Process.sleep(:infinity) end)}}),
        request.({:chars, [:x]}),
        request.({:output, [:x]})
      ]
      IO.write("still captured")
      forged
      """

      assert {:ok, %{"value" => [error, error, error], "output" => "still captured"}} =
               Kettlecorn.eval(vm, code, timeout: 5_000)

      assert error == {:error, :put_chars}
    end

    test "a formatting callback's processes die with the evaluation, and its output is captured",
         %{vm: vm} do
      code = ~S"""
      cmp = fn _, _ ->
        spawn(fn -> Process.register(self(), :escapee); Process.sleep(:infinity) end)
        Process.sleep(:infinity)
      end

      :io.format(~c"~Kp~n", [cmp, %{a: 1, b: 2}])
      """

      assert {:error, %{"kind" => "timeout"}} = Kettlecorn.eval(vm, code, timeout: 500)
      assert_guest_exit(vm, :escapee)

      code =
        ~S|:io.format(~c"~Kp~n", [fn a, b -> IO.write("compared "); a <= b end, %{a: 1, b: 2}])|

      assert {:ok, %{"output" => "compared " <> _}} = Kettlecorn.eval(vm, code)
    end

    test "without the evaluator, eval/3 returns call/4's error", %{vm: vm} do
      {:ok, _} = Kettlecorn.eval(vm, "Process.unregister(:kettlecorn_evaluator)")
      assert {:error, :noproc} = Kettlecorn.eval(vm, "1")
    end

    test "a result too large to walk comes back inspected only, within the timeout", %{vm: vm} do
      # 2^40 nodes, shared: cheap to build, but not to walk, copy or print.
      for {code, language} <- [
            {"Enum.reduce(1..40, :x, fn _, t -> {t, t} end)", :elixir},
            {"lists:foldl(fun(_, T) -> {T, T} end, x, lists:seq(1, 40)).", :erlang}
          ] do
        assert {:ok, %{"inspected" => "{{{" <> _} = result} =
                 Kettlecorn.eval(vm, code, language: language, timeout: 5_000)

        refute Map.has_key?(result, "value")
      end
    end

    test "an evaluation that kills its group leader still stops at its timeout", %{vm: vm} do
      code = ~S"""
      Process.register(self(), :spinner)
      Process.exit(Process.group_leader(), :kill)
      Stream.repeatedly(fn -> 1 end) |> Stream.run()
      """

      assert {:error, %{"kind" => "timeout"}} = Kettlecorn.eval(vm, code, timeout: 500)
      assert_guest_exit(vm, :spinner)
    end

    test "a timed-out evaluation's processes die while its output requests keep the leader busy",
         %{vm: vm} do
      # Keep the leader backlogged without exhausting VM memory before
      # the timeout can exercise process cleanup.
      code = ~S"""
      spawn(fn -> Process.register(self(), :escapee); Process.sleep(:infinity) end)
      data = :binary.copy("x", 64_000)
      gl = Process.group_leader()
      request = {:put_chars, :unicode, data}
      Stream.repeatedly(fn -> send(gl, {:io_request, self(), make_ref(), request}) end) |> Stream.run()
      """

      assert {:error, %{"kind" => "timeout"}} = Kettlecorn.eval(vm, code, timeout: 300)
      assert_guest_exit(vm, :escapee)
    end

    test "a timed-out evaluation's processes die, however fast they spawn", %{vm: vm} do
      {:ok, %{"value" => before}} = Kettlecorn.eval(vm, "length(Process.list())")

      # Every process starts another before it sleeps: :spawned trace
      # messages are always on the way when the timeout kills the others.
      code = ~S"""
      chain = fn chain -> spawn(fn -> chain.(chain) end); Process.sleep(:infinity) end
      spawn(fn -> chain.(chain) end)
      Process.sleep(:infinity)
      """

      assert {:error, %{"kind" => "timeout"}} = Kettlecorn.eval(vm, code, timeout: 300)
      Process.sleep(500)
      {:ok, %{"value" => later}} = Kettlecorn.eval(vm, "length(Process.list())")
      assert later <= before + 2
    end

    test "infinite timeouts", %{vm: vm} do
      assert {:ok, %{"value" => 2}} = Kettlecorn.eval(vm, "1 + 1", timeout: :infinity)
    end

    test "non-plain results come back only as inspected strings", %{vm: vm} do
      assert {:ok, result} = Kettlecorn.eval(vm, "{self(), fn -> 1 end, make_ref()}")
      refute Map.has_key?(result, "value")
      assert result["inspected"] =~ "#PID<"
    end

    test "structs come back as Kettlecorn.Struct", %{vm: vm} do
      assert {:ok, %{"value" => {:ok, %Kettlecorn.Struct{module: URI, fields: fields}}}} =
               Kettlecorn.eval(vm, ~S|{:ok, URI.parse("http://example.com")}|)

      assert %{host: "example.com", scheme: "http"} = fields
    end
  end

  describe "eval/3 with language: :erlang" do
    test "evaluates expressions like the Erlang shell", %{vm: vm} do
      assert {:ok, %{"value" => 21, "output" => "N is 20\n"}} =
               Kettlecorn.eval(vm, ~S|M = N + 1, io:format("N is ~p~n", [N]). M|,
                 language: :erlang,
                 binding: %{"N" => 20}
               )

      assert {:ok, %{"inspected" => "{\"hi\",<0." <> _}} =
               Kettlecorn.eval(vm, ~S|{"hi", self()}|, language: :erlang)
    end

    test "compiles and loads modules", %{vm: vm} do
      module = ~S"""
      -module(geometry).
      -export([area/1]).
      area({square, Side}) -> Side * Side.
      """

      assert {:ok, %{"value" => {:module, :geometry}}} =
               Kettlecorn.eval(vm, module, language: :erlang)

      assert {:ok, %{"value" => 9}} =
               Kettlecorn.eval(vm, "geometry:area({square, 3}).", language: :erlang)

      assert {:ok, %{"value" => 16}} = Kettlecorn.eval(vm, ":geometry.area({:square, 4})")
    end

    test "reports errors as Erlang does", %{vm: vm} do
      assert {:error, %{"kind" => "error", "message" => "nofile:1:5: syntax error before: " <> _}} =
               Kettlecorn.eval(vm, "1 + .", language: :erlang)

      assert {:error, %{"kind" => "error", "message" => "nofile:2:8: function f/0 undefined"}} =
               Kettlecorn.eval(vm, "-module(m).\ng() -> f().", language: :erlang)

      assert {:error, %{"kind" => "error", "message" => message}} =
               Kettlecorn.eval(vm, "1 + a.", language: :erlang)

      assert message =~
               "exception error: an error occurred when evaluating an arithmetic expression"

      assert {:error, %{"message" => "nofile:1:1: no expression"}} =
               Kettlecorn.eval(vm, "", language: :erlang)

      assert {:error, %{"message" => "exception error: undefined shell command f/0"}} =
               Kettlecorn.eval(vm, "f().", language: :erlang)

      assert {:error, %{"kind" => "throw", "message" => "exception throw: oops" <> _}} =
               Kettlecorn.eval(vm, "throw(oops).", language: :erlang)
    end
  end

  describe "isolation" do
    test "no network", %{vm: vm} do
      assert {:ok, %{"value" => {:error, _}}} =
               Kettlecorn.eval(vm, ~S|:gen_tcp.connect(~c"127.0.0.1", 22, [], 1000)|)

      assert {:ok, %{"value" => {:error, _}}} =
               Kettlecorn.eval(vm, ~S|:inet.gethostbyname(~c"example.com")|)
    end

    test "no OS processes", %{vm: vm} do
      assert {:error, %{"kind" => "error"}} = Kettlecorn.eval(vm, ~S|System.cmd("ls", ["/"])|)
      assert {:error, _} = Kettlecorn.eval(vm, ~S|:os.cmd(~c"ls")|)
    end

    test "no native code", %{vm: vm} do
      assert {:ok, %{"value" => {:error, _}}} =
               Kettlecorn.eval(vm, ~S|:erlang.load_nif(~c"/tmp/evil", 0)|)

      assert {:ok, %{"value" => {:error, _}}} =
               Kettlecorn.eval(vm, ~S|:erl_ddll.load_driver(~c"/tmp", ~c"evil")|)
    end

    test "the host file system is invisible; writes stay in the VM's private root", %{vm: vm} do
      assert {:ok, %{"value" => {:error, :enoent}}} =
               Kettlecorn.eval(vm, ~S|File.read("/etc/passwd")|)

      assert {:ok, %{"value" => {:error, _}}} =
               Kettlecorn.eval(vm, ~S|File.read("/../../etc/passwd")|)

      assert {:ok, %{"value" => :ok}} =
               Kettlecorn.eval(
                 vm,
                 ~S|File.write("/lib/elixir/ebin/Elixir.Enum.beam", "garbage")|
               )

      runtime_enum = Path.join(TestRuntime.runtime(), "root/lib/elixir/ebin/Elixir.Enum.beam")
      refute File.read!(runtime_enum) == "garbage"

      {:ok, other} = Kettlecorn.start_link(TestRuntime.opts())
      assert {:ok, %{"value" => 6}} = Kettlecorn.eval(other, "Enum.sum([1, 2, 3])")
      Kettlecorn.stop(other)
    end

    test "environment variables of the host are not visible", %{vm: vm} do
      System.put_env("KETTLECORN_TEST_SECRET", "hunter2")

      assert {:ok, %{"value" => nil}} =
               Kettlecorn.eval(vm, ~S|System.get_env("KETTLECORN_TEST_SECRET")|)
    end
  end

  describe "resource limits" do
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
      assert_receive {:DOWN, ^ref, :process, ^vm, {:shutdown, {:vm_down, ^reason}}}, 5_000
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

      assert_receive {:DOWN, ^ref, :process, ^vm, {:shutdown, {:vm_down, :out_of_fuel}}}, 5_000
    end

    test "busy guests can't block a call forever", %{vm: vm} do
      # A guest process spinning outside the evaluator's control.
      {:ok, _} =
        Kettlecorn.eval(
          vm,
          "spawn(fn -> Stream.repeatedly(fn -> 1 end) |> Stream.run() end); :ok"
        )

      assert {:ok, %{"value" => 2}} = Kettlecorn.eval(vm, "1 + 1")
    end
  end

  describe "messages, calls and casts" do
    test "call/cast reach GenServers in the guest", %{vm: vm} do
      {:ok, _} =
        Kettlecorn.eval(vm, """
        defmodule Counter do
          use GenServer
          def init(n), do: {:ok, n}
          def handle_call({:add, k}, _from, n), do: {:reply, n + k, n + k}
          def handle_cast(:reset, _n), do: {:noreply, 0}
        end
        {:ok, _} = GenServer.start(Counter, 0, name: :counter)
        """)

      assert {:ok, 5} = Kettlecorn.call(vm, :counter, {:add, 5})
      assert {:ok, 7} = Kettlecorn.call(vm, "counter", {:add, 2})
      :ok = Kettlecorn.cast(vm, :counter, :reset)
      assert {:ok, 1} = Kettlecorn.call(vm, :counter, {:add, 1})
      assert {:error, :noproc} = Kettlecorn.call(vm, :no_such_process, :ok)
    end

    test "a malformed proxy result completes the call with an error", %{vm: vm} do
      assert {:ok, _} =
               Kettlecorn.eval(vm, ~S"""
               Process.unregister(:kettlecorn_proxy)
               proxy = spawn(fn ->
                 receive do
                   {:wasm, {id, _request}} ->
                     Kettlecorn.Event.send(%{event: :proxy_reply, id: id, result: "invalid"})
                 end
               end)
               Process.register(proxy, :kettlecorn_proxy)
               """)

      assert {:error, {:bad_reply, "invalid"}} = Kettlecorn.call(vm, "target", :request)
    end

    test "send reaches registered names and guest pid handles", %{vm: vm} do
      {:ok, _} =
        Kettlecorn.eval(vm, """
        pid = spawn(fn ->
          for _ <- 1..2 do
            receive do
              {:wasm, {:ping, n}} -> Kettlecorn.Host.send({:pong, n * 2, self()})
            end
          end
        end)
        Process.register(pid, :echo)
        """)

      assert :ok = Kettlecorn.send(vm, :echo, {:ping, 21})

      assert_receive {:kettlecorn, ^vm, {:message, {:pong, 42, %Kettlecorn.Pid{} = guest_pid}}},
                     5_000

      assert :ok = Kettlecorn.send(vm, guest_pid, {:ping, 10})
      assert_receive {:kettlecorn, ^vm, {:message, {:pong, 20, ^guest_pid}}}, 5_000

      assert {:error, :noproc} = Kettlecorn.send(vm, :nobody, :ok)
      # The guest decodes host payloads with [:safe]: no new atoms.
      assert {:error, :bad_payload} = Kettlecorn.send(vm, :echo, :an_atom_the_guest_lacks_xyz)
      # The guest pid is only a handle for addressing the guest again.
      assert {:error, :noproc} = Kettlecorn.send(vm, guest_pid, :ok)
    end

    test "guest PID handles cannot be sent to another VM", %{vm: vm} do
      assert {:ok, _} = Kettlecorn.eval(vm, "Kettlecorn.Host.send(self())")
      assert_receive {:kettlecorn, ^vm, {:message, %Kettlecorn.Pid{vm: ^vm} = target}}, 5_000
      {:ok, other} = Kettlecorn.start_link(TestRuntime.opts())
      on_exit(fn -> Kettlecorn.stop(other) end)
      assert {:error, :wrong_vm} = Kettlecorn.send(other, target, :ok)
      assert {:ok, %{"value" => 1}} = Kettlecorn.eval(other, "1")
    end

    test "write_stdin/2 and close_stdin/1 feed the guest's standard input", %{vm: vm} do
      # Inside eval/3, :stdio is the evaluator's capture device; the VM's own
      # standard input is the :user device.
      code = ~S|IO.read(Process.whereis(:user), :eof)|
      task = Task.async(fn -> Kettlecorn.eval(vm, code, timeout: 10_000) end)
      Kettlecorn.write_stdin(vm, "line one\n")
      Kettlecorn.write_stdin(vm, "line two\n")
      Kettlecorn.close_stdin(vm)
      assert {:ok, %{"value" => "line one\nline two\n"}} = Task.await(task, 15_000)
    end

    test "guest console output is streamed to the owner", %{vm: vm} do
      # Output of eval'd code is captured; output to the VM's console is streamed.
      {:ok, _} = Kettlecorn.eval(vm, ~S|IO.puts(Process.whereis(:user), "from a guest process")|)
      assert_receive {:kettlecorn, ^vm, {:stdout, "from a guest process\n"}}, 5_000
    end

    test "buffered console output retains only the bytes within the cap" do
      limit = 256 * 1024
      {:ok, vm} = Kettlecorn.start_link(TestRuntime.opts(output_limit: limit))
      on_exit(fn -> Kettlecorn.stop(vm) end)
      Kettlecorn.take_output(vm)

      code = ~S|IO.write(Process.whereis(:user), String.duplicate("x", 8 * 1024 * 1024)); :ok|
      assert {:ok, %{"value" => :ok}} = Kettlecorn.eval(vm, code, timeout: 30_000)

      # Wait for the port message's handler to finish before measuring retained binaries.
      :sys.get_state(vm)
      :erlang.garbage_collect(vm)
      {:binary, binaries} = Process.info(vm, :binary)
      assert Enum.sum(for {_, size, _} <- binaries, do: size) < limit + 1024
      assert Kettlecorn.take_output(vm) == String.duplicate("x", limit)
      assert Kettlecorn.take_output(vm) == ""
    end

    test "Kettlecorn.Host.call/3 is a host call", %{vm: vm} do
      task =
        Task.async(fn ->
          Kettlecorn.eval(vm, ~S|Kettlecorn.Host.call("double", %{n: 21})|)
        end)

      assert_receive {:kettlecorn, ^vm, {:host_call, reply_to, "double", %{n: 21}}}, 5_000
      :ok = Kettlecorn.reply(vm, reply_to, {:ok, 42})
      assert {:ok, %{"value" => {:ok, 42}}} = Task.await(task)
    end

    test "host calls preserve errors and timeouts", %{vm: vm} do
      task = Task.async(fn -> Kettlecorn.eval(vm, ~S|Kettlecorn.Host.call("denied")|) end)
      assert_receive {:kettlecorn, ^vm, {:host_call, reply_to, "denied", %{}}}, 5_000
      assert :ok = Kettlecorn.reply(vm, reply_to, {:error, "denied"})
      assert {:ok, %{"value" => {:error, "denied"}}} = Task.await(task)

      assert {:ok, %{"value" => {:error, :timeout}}} =
               Kettlecorn.eval(vm, ~S|Kettlecorn.Host.call("unanswered", %{}, timeout: 10)|)
    end

    test "guest messages are delivered as sent, whatever their shape", %{vm: vm} do
      code = ~S|Kettlecorn.Host.send(%{"_kettlecorn" => %{"t" => "boot_ready"}})|
      assert {:ok, _} = Kettlecorn.eval(vm, code)

      assert_receive {:kettlecorn, ^vm, {:message, %{"_kettlecorn" => %{"t" => "boot_ready"}}}},
                     5_000
    end

    test "guest messages can't smuggle live terms to the host", %{vm: vm} do
      {:ok, _} =
        Kettlecorn.eval(vm, ~S"""
        Kettlecorn.Host.send({self(), :some_atom_the_host_lacks_xyz, make_ref()})
        Kettlecorn.Host.send(%{__struct__: File.Stream, path: "/etc/passwd", modes: [], line_or_bytes: :line, raw: true})
        Kettlecorn.Host.send(fn -> :evil end)
        """)

      assert_receive {:kettlecorn, ^vm,
                      {:message,
                       {%Kettlecorn.Pid{}, {:unknown_atom, "some_atom_the_host_lacks_xyz"},
                        %Kettlecorn.Opaque{}}}},
                     5_000

      # A struct of a host module arrives as data: enumerating it reads nothing.
      assert_receive {:kettlecorn, ^vm,
                      {:message,
                       %Kettlecorn.Struct{module: File.Stream, fields: %{path: "/etc/passwd"}}}},
                     5_000

      # The fun is dropped by the decoder, the VM keeps working.
      refute_receive {:kettlecorn, ^vm, {:message, _}}, 500
      assert {:ok, _} = Kettlecorn.eval(vm, "1")
    end
  end

  describe "failures" do
    test "bad targets raise in the caller, not in the VM", %{vm: vm} do
      assert_raise ArgumentError, fn -> Kettlecorn.call(vm, 123, :x) end
      assert_raise ArgumentError, fn -> Kettlecorn.cast(vm, "", :x) end
      assert_raise ArgumentError, fn -> Kettlecorn.send(vm, nil, :x) end

      assert_raise ArgumentError, ~r/invalid timeout/, fn ->
        Kettlecorn.call(vm, :x, :y, "5000")
      end

      assert_raise ArgumentError, ~r/invalid timeout/, fn -> Kettlecorn.send(vm, :x, :y, -1) end

      assert {:ok, %{"value" => 1}} = Kettlecorn.eval(vm, "1")
    end

    test "invalid and oversized outbound data leaves the VM running", %{vm: vm} do
      assert_raise ArgumentError, fn -> Kettlecorn.write_stdin(vm, [:invalid]) end
      assert_raise ArgumentError, fn -> Kettlecorn.reply(vm, nil, {:ok, 1}) end
      large = :binary.copy("x", 64 * 1024 * 1024)
      assert_raise ArgumentError, ~r/cannot exceed/, fn -> Kettlecorn.send(vm, :target, large) end
      assert_raise ArgumentError, ~r/cannot exceed/, fn -> Kettlecorn.call(vm, :target, large) end
      assert_raise ArgumentError, ~r/cannot exceed/, fn -> Kettlecorn.write_stdin(vm, large) end
      assert {:ok, %{"value" => 1}} = Kettlecorn.eval(vm, "1")
    end

    @tag :tmp_dir
    test "an application that fails to start fails the boot at once", %{tmp_dir: dir} do
      started = System.monotonic_time(:millisecond)

      for start <- [&Kettlecorn.start/1, &Kettlecorn.start_link/1] do
        assert {:error, :boot_failed} =
                 start.(
                   TestRuntime.opts(
                     apps: [:no_such_app],
                     boot_timeout: 60_000,
                     instances_dir: dir
                   )
                 )
      end

      assert File.ls!(dir) == []
      assert System.monotonic_time(:millisecond) - started < 30_000
    end

    @tag :tmp_dir
    test "preparation and launch failures remove instance directories", %{tmp_dir: dir} do
      missing = Path.join(dir, "missing")

      assert {:error, {:prepare_failed, _message}} =
               Kettlecorn.start_link(TestRuntime.opts(instances_dir: dir, code_paths: [missing]))

      assert File.ls!(dir) == []
    end

    test "a VM whose boot times out leaves no launcher process or directory behind" do
      dir = Path.join(System.tmp_dir!(), "kettlecorn-test-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(dir) end)

      for start <- [&Kettlecorn.start/1, &Kettlecorn.start_link/1] do
        assert {:error, {:vm_down, :boot_timeout}} =
                 start.(TestRuntime.opts(boot_timeout: 1, instances_dir: dir))
      end

      assert File.ls!(dir) == []
      {processes, 0} = System.cmd("ps", ["-A", "-o", "args="])
      refute processes =~ dir
    end

    @tag :tmp_dir
    test "start_link returns an early launcher failure without exiting the caller", %{
      tmp_dir: dir
    } do
      assert {:error, {:vm_down, {:exit_status, status, stderr}}} =
               Kettlecorn.start_link(
                 TestRuntime.opts(instances_dir: dir, max_memory: 18_446_744_073_709_551_616)
               )

      assert status != 0
      assert stderr =~ "--max-memory"
      assert File.ls!(dir) == []
    end

    test "a request the guest never answers fails at its deadline" do
      {:ok, vm} = Kettlecorn.start(TestRuntime.opts())

      # Half a second later, a process at max priority takes the only
      # scheduler: the guest's proxy never runs again.
      {:ok, _} =
        Kettlecorn.eval(vm, """
        spawn(fn ->
          Process.sleep(500)
          Process.flag(:priority, :max)
          Stream.repeatedly(fn -> 1 end) |> Stream.run()
        end)
        """)

      Process.sleep(1_000)
      assert {:error, :timeout} = Kettlecorn.call(vm, :anyone, :hello, 200)
      Kettlecorn.stop(vm)
    end

    test "a frame over :max_message_size kills the VM" do
      {:ok, vm} = Kettlecorn.start(TestRuntime.opts(max_message_size: 10_000))
      code = ~S|Kettlecorn.Host.send(String.duplicate("x", 20_000))|

      assert {:error, {:vm_down, {:frame_too_large, length}}} = Kettlecorn.eval(vm, code)
      assert length > 10_000
    end
  end

  test "run/2 evaluates in a throwaway VM" do
    assert {:ok, %{"value" => 120}} =
             Kettlecorn.run("Enum.reduce(1..5, &*/2)", TestRuntime.opts())

    assert {:ok, %{"value" => 42}} =
             Kettlecorn.run(
               "N + 1.",
               TestRuntime.opts(language: :erlang, binding: [{"N", 41}], timeout: 10_000)
             )
  end

  test "several VMs run concurrently" do
    results =
      1..4
      |> Task.async_stream(fn i -> Kettlecorn.run("#{i} * 10", TestRuntime.opts()) end,
        timeout: 60_000,
        max_concurrency: 4
      )
      |> Enum.map(fn {:ok, {:ok, %{"value" => v}}} -> v end)

    assert results == [10, 20, 30, 40]
  end

  defp assert_guest_exit(vm, name) do
    code = ~S"""
    case Process.whereis(name) do
      nil -> :stopped
      pid ->
        ref = Process.monitor(pid)
        receive do
          {:DOWN, ^ref, :process, ^pid, _reason} -> :stopped
        after
          1_000 -> :still_alive
        end
    end
    """

    assert {:ok, %{"value" => :stopped}} = Kettlecorn.eval(vm, code, binding: %{name: name})
  end
end
