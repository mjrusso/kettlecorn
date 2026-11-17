# Run this host-side driver with `just demo` from the repository root.
# Source strings passed to Kettlecorn.eval/3 execute in the guest;
# this script and its calls to the host library execute on the host.

{:ok, vm} =
  Kettlecorn.start_link(
    owner: self(),
    max_memory: 256 * 1024 * 1024,
    max_lifetime: 60_000,
    max_fuel: 50_000_000_000
  )

IO.puts("== 1. Evaluate untrusted code, capture its output")
{:ok, result} = Kettlecorn.eval(vm, ~S|IO.puts("hello from the guest"); Enum.sum(1..100)|)
IO.inspect(result)

IO.puts("\n== 2. Errors and timeouts come back as data")
IO.inspect(Kettlecorn.eval(vm, ~S|File.read!("/etc/passwd")|) |> elem(1) |> Map.get("message") |> String.slice(0, 70))
IO.inspect(Kettlecorn.eval(vm, "Process.sleep(:infinity)", timeout: 300))

IO.puts("\n== 3. Define a GenServer in the guest and talk to it from the host")

{:ok, _} =
  Kettlecorn.eval(vm, """
  defmodule KV do
    use GenServer
    def init(map), do: {:ok, map}
    def handle_call({:get, k}, _from, map), do: {:reply, Map.get(map, k), map}
    def handle_call(:keys, _from, map), do: {:reply, Map.keys(map), map}
    def handle_cast({:put, k, v}, map), do: {:noreply, Map.put(map, k, v)}
  end

  {:ok, _} = GenServer.start(KV, %{}, name: :kv)
  """)

:ok = Kettlecorn.cast(vm, :kv, {:put, "language", "Elixir"})
:ok = Kettlecorn.cast(vm, :kv, {:put, "vm", "BEAM in WebAssembly"})
IO.inspect(Kettlecorn.call(vm, :kv, {:get, "vm"}), label: "call :kv {:get, \"vm\"}")
IO.inspect(Kettlecorn.call(vm, :kv, :keys), label: "call :kv :keys")
IO.inspect(Kettlecorn.call(vm, :nobody, :keys), label: "call to a missing process")

IO.puts("\n== 4. Messages both ways")

{:ok, _} =
  Kettlecorn.eval(vm, """
  pid =
    spawn(fn ->
      loop = fn loop ->
        receive do
          {:wasm, {:fib, n}} ->
            fib = Stream.unfold({0, 1}, fn {a, b} -> {a, {b, a + b}} end) |> Enum.at(n)
            Kettlecorn.Host.send({:fib_result, n, fib})
            loop.(loop)
        end
      end

      loop.(loop)
    end)

  Process.register(pid, :fib_worker)
  """)

for n <- [10, 50, 100], do: :ok = Kettlecorn.send(vm, :fib_worker, {:fib, n})

for _ <- 1..3 do
  receive do
    {:kettlecorn, ^vm, {:message, {:fib_result, n, fib}}} ->
      Kettlecorn.acknowledge(vm)
      IO.puts("fib(#{n}) = #{fib}")
  after
    5_000 -> raise "no reply"
  end
end

IO.puts("\n== 5. Host calls: the guest asks the host for something")
# Kettlecorn.Host.call/2 in the guest asks the host; the host decides what
# to allow. Here it exposes a single "now" capability.
task = Task.async(fn -> Kettlecorn.eval(vm, ~S|Kettlecorn.Host.call("now")|) end)

receive do
  {:kettlecorn, ^vm, {:host_call, reply_to, "now", _args}} ->
    Kettlecorn.reply(vm, reply_to, {:ok, DateTime.utc_now() |> DateTime.to_iso8601()})
    Kettlecorn.acknowledge(vm)
after
  5_000 -> raise "guest did not request the current time"
end

IO.inspect(Task.await(task) |> elem(1) |> Map.get("value"), label: "guest got")

IO.puts("\n== 6. Runaway code stops at the CPU budget")
{:ok, hog} = Kettlecorn.start(max_fuel: 3_000_000_000, max_lifetime: 30_000)
IO.inspect(Kettlecorn.eval(hog, "Stream.repeatedly(fn -> 1 end) |> Stream.run()", timeout: 60_000))

Kettlecorn.stop(vm)
