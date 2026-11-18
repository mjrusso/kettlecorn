# Examples

Install the CLI using the [CLI guide](../host/guides/running-applications.md#command-line),
then run these commands from the repository root with `kr` as shorthand:

```bash
alias kr=kettlecorn-run
```

Console transcripts show representative output. PIDs, random bytes, response
sizes, and installed version strings vary between runs.

## Scripts

### Hello world: [`01_hello.exs`](01_hello.exs)

```console
$ kr examples/01_hello.exs one two
Hello from Elixir 1.20.5 on OTP 29!
Running on: wasm32-unknown-wasi
Arguments: ["one", "two"]
```

### Processes and message passing: [`02_processes.exs`](02_processes.exs)

Spawns workers and collects their replies, passes a token around a ring of
1000 processes, and monitors a process that crashes:

```console
$ kr examples/02_processes.exs
#PID<0.127.0> squared 1 -> 1
#PID<0.128.0> squared 2 -> 4
#PID<0.129.0> squared 3 -> 9
#PID<0.130.0> squared 4 -> 16
#PID<0.131.0> squared 5 -> 25
Passed a token around a ring of 1000 processes
Monitored process exited with :boom
```

### A GenServer under supervision: [`03_genserver.exs`](03_genserver.exs)

A `DynamicSupervisor` manages bank account GenServers. A `Registry` locates
them for 100 concurrent `Task`s. The supervisor restarts an account after a
crash:

```console
$ kr examples/03_genserver.exs
alice deposits 100: {:ok, 100}
alice withdraws 30: {:ok, 70}
bob withdraws 10: {:error, :insufficient_funds}
bob after 100 concurrent deposits: 100
alice crashed and was restarted: #PID<0.131.0> -> #PID<0.234.0>
alice's balance after restart: 0
```

### Standard input: [`04_stdin.exs`](04_stdin.exs)

```console
$ printf 'the quick brown fox jumps over the lazy dog the end\nthe fox again and the dog\n' \
    | kr examples/04_stdin.exs
the        5
dog        2
fox        2
again      1
and        1
```

### Runaway programs: [`05_runaway.exs`](05_runaway.exs)

These runs stop at the CPU, time, and memory limits, respectively.
The fuel and timeout runs exit with status 1. Selected output is shown below:

```console
$ kr --fuel 5000000000 examples/05_runaway.exs
spinning forever...
guest exhausted its fuel

$ kr --timeout 2s examples/05_runaway.exs
spinning forever...
guest execution timed out

$ kr --max-memory 67108864 examples/05_runaway.exs memory
allocating forever...
BEAM fatal error: binary_alloc: Cannot allocate 1000000 bytes of memory (of type "binary").
```

### Crypto, HTTP and sockets: [`06_network.exs`](06_network.exs)

Crypto is always available. HTTP (`wasi:http`, through `Kettlecorn.HTTP`) and
sockets (`wasi:sockets`, through `:gen_tcp`) work only when granted, and each
grant allows *any* destination (see
[network grants](../host/guides/sandbox.md#network-grants)). This example
runs against a local `python3 -m http.server 8767`:

```console
$ kr examples/06_network.exs http://127.0.0.1:8767/
sha256("hello") = 2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824
16 random bytes: vGOCibcDSkOpKkxd64XlkA==

HTTP via wasi:http (Kettlecorn.HTTP), available: false
  error: :unsupported

TCP via wasi:sockets (:gen_tcp)
  error: :eacces

$ kr --http --network examples/06_network.exs http://127.0.0.1:8767/
...
HTTP via wasi:http (Kettlecorn.HTTP), available: true
  200, 5029 bytes

TCP via wasi:sockets (:gen_tcp)
  HTTP/1.0 200 OK
```

Req is in the runtime too. Plain `Req.get!/2` goes through `Kettlecorn.HTTP`
with `--http`, and through Finch over sockets with `--network`.

## Interactive IEx

```console
$ nix run .#iex          # or: kr --iex, just iex
Interactive Elixir (1.20.5) - press Ctrl+C to exit (type h() ENTER for help)
iex(1)> Enum.ma<Tab>
map/2                map_every/3          map_intersperse/3
map_join/2           map_join/3           map_reduce/3
...
```

IEx supports line editing, history (↑/↓), tab completion, and colours.
Ctrl+C stops the VM. With piped input, it reads lines and exits at end of input:

```console
$ printf 'x = 6 * 7\nIO.puts("x=#{x}")\n' | kr --iex
...
iex(1)> 42
iex(2)> x=42
:ok
```

`--iex script.exs` loads the script before the first prompt.

## Cooked apps

From the repository root, enter `nix develop` and run `just example counter`,
`just example csv_stats -e 'CsvStats.report()'`, or `just example lua`.
The `example` recipe cooks the app with Mix, then runs it in IEx unless
other launcher arguments are supplied. `just build-examples` discovers and
cooks every project under `examples/apps/` without starting VMs.

Cooked apps are written to `_kettlecorn/examples/<name>/`. Each example uses
its own `mix.lock` and the host library's `mix kettlecorn.cook` task.
Kettlecorn is a path dependency with `runtime: false`, so the host library is
excluded from the guest bundle.

Cooking compiles code on the host. Use trusted projects and dependencies,
or isolate the build separately. See [Running applications](../host/guides/running-applications.md#cooking-mix-applications)
for the build trust boundary, compiler requirements, and deployment.

The launcher supports these modes:

| Command | Behavior |
|---|---|
| `kr --app DIR` | Start the application and keep the VM running |
| `kr --app DIR --iex` | Start the application, then enter IEx |
| `kr --app DIR -e CODE` | Start the application, evaluate code, then exit |
| `kr --app DIR script.exs` | Start the application, run the script, then exit |

### [`apps/counter`](apps/counter)

An OTP application with no Hex dependencies. Its supervised GenServer starts
with the value configured in `config/config.exs`.
`just example counter` starts IEx with the application running:

```console
$ just example counter
Interactive Elixir (1.20.5) - press Ctrl+C to exit (type h() ENTER for help)
iex(1)> Counter.value()
10
iex(2)> Counter.increment()
11
iex(3)> Counter.value()
11
```

From a host program, the app's GenServer is reachable with `Kettlecorn.call/4`:

```elixir
{:ok, vm} =
  Kettlecorn.start_link(
    app: "_kettlecorn/examples/counter",
    max_fuel: 50_000_000_000,
    max_lifetime: 30_000
  )
{:ok, 10} = Kettlecorn.call(vm, :counter, :value)
{:ok, 11} = Kettlecorn.call(vm, :counter, :increment)
Kettlecorn.stop(vm)
```

### [`apps/csv_stats`](apps/csv_stats)

`CsvStats` uses [NimbleCSV](https://hex.pm/packages/nimble_csv) to summarize
sales from a file in `priv/`. The configured currency is EUR:

```console
$ just example csv_stats -e 'CsvStats.report()'
Revenue by region (EUR):
  east   948.00
  north  828.80
  west   525.00
  south  516.80
```

### [`apps/lua`](apps/lua)

A supervised GenServer runs [Lua 1.0.2](https://lua.hexdocs.pm/Lua.html)
inside Kettlecorn. The Lua function in `priv/transform.lua` calculates an
order total in integer cents, chooses a route, and counts processed orders.
It returns only the ID, total, route, and count, omitting customer email.

```console
$ just example lua
iex(1)> event = %{"id" => "order-1", "email" => "ada@example.test", "items" => [%{"unit_price_cents" => 2500, "quantity" => 2}]}
iex(2)> LuaExample.transform(event)
{:ok, ["order-1", 5000, "standard", 1]}
iex(3)> LuaExample.transform(event)
{:ok, ["order-1", 5000, "standard", 2]}
```

From the host, start the cooked app and call its registered GenServer:

```elixir
event = %{
  "id" => "order-1",
  "email" => "ada@example.test",
  "items" => [%{"unit_price_cents" => 2500, "quantity" => 2}]
}

{:ok, vm} =
  Kettlecorn.start_link(
    app: "_kettlecorn/examples/lua",
    max_fuel: 100_000_000_000,
    max_lifetime: 30_000
  )

{:ok, {:ok, ["order-1", 5000, "standard", 1]}} =
  Kettlecorn.call(vm, :lua_example, {:transform, event})

Kettlecorn.stop(vm)
```

Lua errors return as `{:error, message}`; the Lua state is retained between
calls, including mutations made before an error. The example also sets Lua
limits on instructions, call depth, and string size.
The app bundles its own Lua dependency.

The [comparison notebook](../host/notebooks/lua.livemd) loads Lua directly
from Livebook, runs the same transformation on the host and in the guest,
and exposes a controlled host operation without cooking an app.

## From a host program: [`host_demo.exs`](host_demo.exs)

Inside `nix develop`, run:

```sh
just demo
```

The demo evaluates guest code, handles errors and timeouts, calls a guest
GenServer, exchanges messages, answers requests from the guest, and stops
a runaway VM at its CPU budget. The driver runs on the host; source passed
to `Kettlecorn.eval/3` runs in the guest.

The [Working with guest VMs notebook](../host/notebooks/working-with-guests.livemd)
walks through GenServers, messaging, and host calls.
