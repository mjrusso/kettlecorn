# Run with `just bench-startup`; BENCH_TIME sets seconds per scenario.
# VM starts include copying the guest root and booting OTP. Cold starts
# disable the launcher's component cache. See host/guides/performance.md.

time = String.to_integer(System.get_env("BENCH_TIME", "10"))
runtime = System.fetch_env!("KETTLECORN_RUNTIME")

start_stop = fn opts ->
  {:ok, vm} = Kettlecorn.start(Keyword.put(opts, :runtime, runtime))
  :ok = Kettlecorn.stop(vm)
end

run_cli = fn args ->
  {_, 0} =
    System.cmd(Path.expand("../../bin/kettlecorn-run", __DIR__), args,
      env: [{"KETTLECORN_RUNTIME", runtime}],
      stderr_to_stdout: true
    )
end

# Populate the component cache before measuring cached starts.
start_stop.([])

Benchee.run(
  %{
    "VM start + stop, cold (component cache disabled)" => fn ->
      start_stop.(compile_cache: false)
    end,
    "VM start + stop, warm" => fn -> start_stop.([]) end,
    "Kettlecorn.run/2: start, eval \"1 + 1\", stop" => fn ->
      {:ok, %{"value" => 2}} = Kettlecorn.run("1 + 1", runtime: runtime)
    end,
    "4 VMs started concurrently, warm" => fn ->
      1..4
      |> Task.async_stream(fn _ -> start_stop.([]) end, max_concurrency: 4, timeout: 60_000)
      |> Stream.run()
    end,
    "kettlecorn-run -e (CLI), warm" => fn -> run_cli.(["-e", "1 + 1"]) end,
    "native: elixir -e, no sandbox" => fn -> {_, 0} = System.cmd("elixir", ["-e", "1 + 1"]) end
  },
  warmup: 0,
  time: time,
  memory_time: 0,
  print: [fast_warning: false]
)
