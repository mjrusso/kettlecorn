# Run with `just bench-workloads`; BENCH_TIME sets seconds per scenario.
# Guest timings include round trips to a running VM. Evaluated programs
# use erl_eval on both sides; compiled programs use the guest interpreter
# and the host JIT. See host/guides/performance.md for the methodology.

time = String.to_integer(System.get_env("BENCH_TIME", "5"))

# The VM's messages go to its owner, but Benchee runs each scenario in a
# process of its own: the owner forwards them to the process that asked last.
forwarder =
  spawn_link(fn ->
    loop = fn loop, to ->
      receive do
        {:reply_to, pid} ->
          loop.(loop, pid)

        {:kettlecorn, vm, _event} = message ->
          if to, do: send(to, message)
          Kettlecorn.acknowledge(vm)
          loop.(loop, to)
      end
    end

    loop.(loop, nil)
  end)

modules = ~S"""
defmodule Bench.Counter do
  use GenServer
  def init(n), do: {:ok, n}
  def handle_call(:incr, _from, n), do: {:reply, n + 1, n + 1}
end

defmodule Bench.Programs do
  def fib(n) when n < 2, do: n
  def fib(n), do: fib(n - 1) + fib(n - 2)

  def run(:fib), do: fib(24)
  def run(:sort), do: for(_ <- 1..100_000, do: :rand.uniform(1_000_000)) |> Enum.sort() |> length()
  def run(:map), do: Map.new(1..100_000, &{&1, &1 * 2}) |> Map.values() |> Enum.sum()

  def run(:processes) do
    me = self()
    for i <- 1..1000, do: spawn(fn -> send(me, i) end)
    for _ <- 1..1000, do: receive(do: (i -> i))
  end

  def run(:compile) do
    name = Module.concat(Bench, "M#{System.unique_integer([:positive])}")
    Module.create(name, quote(do: def(f(x), do: x * 2)), Macro.Env.location(__ENV__))
    # Unload it: the benchmark compiles thousands.
    :code.delete(name) and :code.purge(name)
    :ok
  end

  def run(:json) do
    data = for i <- 1..2000, do: %{"id" => i, "name" => "item #{i}", "tags" => ["a", "b"]}
    data |> JSON.encode!() |> JSON.decode!() |> length()
  end
end

defmodule Bench.Runner do
  use GenServer
  def init(nil), do: {:ok, nil}
  def handle_call({:run, program}, _from, nil), do: {:reply, Bench.Programs.run(program), nil}
end
"""

Code.compile_string(modules)
{:ok, _} = GenServer.start(Bench.Counter, 0, name: :bench_counter)

{:ok, vm} =
  Kettlecorn.start_link(runtime: System.fetch_env!("KETTLECORN_RUNTIME"), owner: forwarder)

{:ok, _} =
  Kettlecorn.eval(
    vm,
    modules <>
      ~S"""
      {:ok, _} = GenServer.start(Bench.Counter, 0, name: :bench_counter)
      {:ok, _} = GenServer.start(Bench.Runner, nil, name: :bench_runner)

      echo = spawn(fn ->
        loop = fn loop ->
          receive do
            {:wasm, payload} -> Kettlecorn.Host.send({:echo, payload}); loop.(loop)
          end
        end
        loop.(loop)
      end)

      Process.register(echo, :bench_echo)
      """,
    timeout: 60_000
  )

Benchee.run(
  %{
    "eval \"1 + 1\"" => fn -> {:ok, %{"value" => 2}} = Kettlecorn.eval(vm, "1 + 1") end,
    "call a guest GenServer" => fn -> {:ok, _} = Kettlecorn.call(vm, :bench_counter, :incr) end,
    "message to a guest process and back" =>
      {fn ->
         :ok = Kettlecorn.send(vm, :bench_echo, :ping)

         receive do
           {:kettlecorn, ^vm, {:message, {:echo, :ping}}} -> :ok
         end
       end,
       before_each: fn input ->
         send(forwarder, {:reply_to, self()})
         input
       end},
    "native: call a GenServer on the host" => fn -> GenServer.call(:bench_counter, :incr) end
  },
  title: "Round trips",
  warmup: 1,
  time: time,
  memory_time: 0
)

programs = %{
  "fib(24), naive recursion" =>
    ~S"f = fn _f, n when n < 2 -> n; f, n -> f.(f, n - 1) + f.(f, n - 2) end; f.(f, 24)",
  "sort 100k random integers" =>
    ~S"for(_ <- 1..100_000, do: :rand.uniform(1_000_000)) |> Enum.sort() |> length()",
  "build and sum a 100k-entry map" =>
    ~S"Map.new(1..100_000, &{&1, &1 * 2}) |> Map.values() |> Enum.sum()",
  "1000 processes, message each and collect" =>
    ~S"me = self(); for i <- 1..1000, do: spawn(fn -> send(me, i) end); for _ <- 1..1000, do: (receive do: (i -> i))",
  "compile a module" => ~S"""
  name = Module.concat(Bench, "M#{System.unique_integer([:positive])}")
  Module.create(name, quote(do: def(f(x), do: x * 2)), Macro.Env.location(__ENV__))
  :code.delete(name) and :code.purge(name)
  :ok
  """,
  "JSON encode + decode" => ~S"""
  data = for i <- 1..2000, do: %{"id" => i, "name" => "item #{i}", "tags" => ["a", "b"]}
  data |> JSON.encode!() |> JSON.decode!() |> length()
  """
}

for {name, code} <- Enum.sort(programs) do
  Benchee.run(
    %{
      "guest" => fn -> {:ok, _} = Kettlecorn.eval(vm, code, timeout: 60_000) end,
      "native" => fn -> Code.eval_string(code) end
    },
    title: "#{name}, evaluated",
    warmup: 1,
    time: time,
    memory_time: 0,
    print: [configuration: false, benchmarking: false]
  )
end

compiled = [
  {"fib(24), naive recursion", :fib},
  {"sort 100k random integers", :sort},
  {"build and sum a 100k-entry map", :map},
  {"1000 processes, message each and collect", :processes},
  {"compile a module", :compile},
  {"JSON encode + decode", :json}
]

for {name, program} <- Enum.sort(compiled) do
  Benchee.run(
    %{
      "guest" => fn -> {:ok, _} = Kettlecorn.call(vm, :bench_runner, {:run, program}, 60_000) end,
      "native" => fn -> Bench.Programs.run(program) end
    },
    title: "#{name}, compiled",
    warmup: 1,
    time: time,
    memory_time: 0,
    print: [configuration: false, benchmarking: false]
  )
end

Kettlecorn.stop(vm)
