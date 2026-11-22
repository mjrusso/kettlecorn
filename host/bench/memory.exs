# Run with `just bench-memory`; BENCH_VMS sets how many VMs to start.
# Reports each idle launcher process's memory from Linux's
# /proc/<pid>/smaps_rollup. See host/guides/performance.md.

count = String.to_integer(System.get_env("BENCH_VMS", "8"))
runtime = System.fetch_env!("KETTLECORN_RUNTIME")

kib = fn text, name ->
  for line <- String.split(text, "\n"),
      [^name, value | _] <- [String.split(line, [":", " "], trim: true)],
      reduce: 0,
      do: (sum -> sum + String.to_integer(value))
end

# Launchers are children of erl_child_setup, which is a child of this BEAM.
launchers = fn ->
  processes =
    for stat <- Path.wildcard("/proc/[0-9]*/stat"),
        {:ok, text} <- [File.read(stat)],
        # The command name is parenthesized and can contain spaces.
        [pid_comm, fields] <- [String.split(text, ") ", parts: 2)],
        [pid, comm] = String.split(pid_comm, " (", parts: 2),
        [_state, ppid | _] <- [String.split(fields)],
        into: %{},
        do: {pid, {comm, ppid}}

  beam = System.pid()

  for {pid, {"kettlecorn-laun" <> _, ppid}} <- processes,
      match?({_, ^beam}, processes[ppid]),
      {:ok, rollup} <- [File.read("/proc/#{pid}/smaps_rollup")] do
    %{
      rss: kib.(rollup, "Rss"),
      private: kib.(rollup, "Private_Clean") + kib.(rollup, "Private_Dirty"),
      pss: kib.(rollup, "Pss")
    }
  end
end

if not File.exists?("/proc/self/smaps_rollup") do
  IO.puts("/proc/self/smaps_rollup is unavailable; this benchmark requires Linux.")
  System.halt(0)
end

# Populate the component cache so starts don't include compilation.
{:ok, vm} = Kettlecorn.start(runtime: runtime)
:ok = Kettlecorn.stop(vm)

vms =
  for _ <- 1..count do
    {:ok, vm} = Kettlecorn.start(runtime: runtime, stop_with: self())
    vm
  end

{:ok, %{"value" => 2}} = Kettlecorn.eval(hd(vms), "1 + 1")
processes = launchers.()
^count = length(processes)

mean = fn key -> Enum.sum(Enum.map(processes, & &1[key])) / count / 1024 end

IO.puts(
  :io_lib.format(
    "Per idle launcher (~B VMs): rss ~.1f MiB   private ~.1f MiB   pss ~.1f MiB",
    [count, mean.(:rss), mean.(:private), mean.(:pss)]
  )
)

Enum.each(vms, &Kettlecorn.stop/1)
