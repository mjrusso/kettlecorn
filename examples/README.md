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

Req is in the runtime too; see [HTTP and Req](../host/guides/running-applications.md#http-and-req)
for its transports and grant behavior.

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
`just example csv_stats -e 'CsvStats.report()'`, `just example lua`, or
`just example dune`. The `example` recipe cooks the app with Mix, then runs
it in IEx unless other launcher arguments are supplied. `just build-examples`
discovers and cooks every project under `examples/apps/` without starting VMs.

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

### [`apps/dune`](apps/dune)

`DuneExample` evaluates Elixir code with [Dune 0.3.18](https://hexdocs.pm/dune/),
which checks the code's calls against an allowlist before running it. Dune's
default allowlist rejects `spawn`, `send`, `receive`, ETS, atom creation, and
system information. [`DuneExample.Allowlist`](apps/dune/lib/dune_example/allowlist.ex)
also rejects functions that read the clock, use `:rand`'s process state, or
return the caller's PID or a new reference. It allows `Kettlecorn.Host.call/3`,
`:rand.seed_s/2` and `:rand.uniform_s/2`, so code can draw random numbers
from a seed the host supplies (see
[controlled inputs](../host/guides/sandbox.md#controlled-inputs)). A session
keeps bindings and modules between evaluations:

```console
$ just example dune
iex(1)> DuneExample.eval("x = 1 + 2; x * 2")
{:ok, "6", ""}
iex(2)> DuneExample.eval("x + 1")
{:ok, "4", ""}
iex(3)> DuneExample.eval("DateTime.utc_now()")
{:error, :restricted,
 "** (DuneRestrictedError) function DateTime.utc_now/0 is restricted"}
```

From a host program, configure a handler for the `"double"` host call. Give
host-call arguments string keys: Dune replaces atoms that evaluated code
creates, so an atom key can reach the host under Dune's replacement name.

```elixir
{:ok, vm} =
  Kettlecorn.start_link(
    app: "_kettlecorn/examples/dune",
    preload: :strict,
    handlers: %{
      "double" => fn
        %{"n" => n} when is_number(n) -> {:ok, 2 * n}
        _args -> {:error, "expected a number"}
      end
    },
    max_fuel: 100_000_000_000,
    max_lifetime: 30_000
  )

code = ~S|Kettlecorn.Host.call("double", %{"n" => 21})|
{:ok, {:ok, "{:ok, 42}", ""}} = Kettlecorn.call(vm, :dune_example, {:eval, code})
Kettlecorn.stop(vm)
```

The example restricts process creation, messaging, and the clock and
random functions listed above. `preload: :strict` loads modules from the
boot-time code path and stops the VM on a later on-demand load. Kettlecorn
provides the isolation boundary.

Dune sets a wall-clock timeout and polls the evaluation's reduction count
in a separate process. The checker competes for the guest's scheduler
while code runs and keeps consuming CPU and fuel while a host call waits.
The stopping point can vary with scheduling and reply timing. This
example runs Dune in a GenServer. Use VM-wide limits such as `max_fuel`
and `max_lifetime` to bound that work.

## Rust projects

Run the recipes in this section from the repository root inside `nix develop`.
The recipes use the runtime built from the checkout. For discovery and
installation in your own Rust project, see the [Rust setup guide](../rust/README.md).

### Hello world

[Hello world](rust/hello-world/) starts an embedded VM, evaluates a greeting,
and shuts down.

```sh
just rust-hello-world
```

The executable takes a runtime directory. To use one you built or extracted:

```sh
cargo run --locked --manifest-path examples/rust/hello-world/Cargo.toml -- /path/to/runtime
```

### Device monitor

The [device monitor](rust/device-monitor/) is a Rust app that runs Elixir monitoring
plugins. Rust reads newline-delimited JSON sensor events and starts a long-lived
BEAM VM for each plugin. Rust evaluates each plugin once at startup, then
uses `Vm::call` to dispatch events to a registered guest process. The plugins
own their device state and alert rules.
The monitor writes one JSON alert per line to stdout and forwards plugin
stdout to stderr.

Run the bundled demo:

```sh
just device-monitor
```

To run with your own telemetry or plugins, build the bundle and pass the file
paths to the executable:

```sh
nix build --accept-flake-config .#rust-device-monitor -o result-rust-device-monitor
bundle=./result-rust-device-monitor
"$bundle/bin/device-monitor" "$bundle/telemetry.jsonl" \
  "$bundle/plugins/sustained_heat.exs" "$bundle/plugins/rapid_rise.exs"
```

[Sustained heat](rust/device-monitor/plugins/sustained_heat.exs) supervises a
`GenServer` per device. It alerts after three consecutive readings of 80 or
higher and reports recovery when the temperature drops below 80.
[Rapid rise](rust/device-monitor/plugins/rapid_rise.exs) tracks each device's last
reading and alerts on a jump of 15 or more.

In the [fixture](rust/device-monitor/telemetry.jsonl), rapid rise alerts on the
north device at 70. A simulated crash then restarts north's sustained-heat
worker. South still alerts on its third high reading, and rapid rise still
remembers north's last reading. North's restarted worker requires three new
high readings. See the [expected JSON output](rust/device-monitor/expected.jsonl).

Pass one or more plugin files to load your own policies. Each `.exs` file
defines `MonitorPlugin.start/0` and `MonitorPlugin.handle_event/1`, both
returning `:ok`. The monitor sends each event to every plugin. Events use
string keys. A `"sample"` event has `"type" => "sample"`, a `"device"`, and an
integer `"temperature"`. The bundled telemetry also includes a `"crash"`
event with a `"device"`. Plugins that use the bundled telemetry must handle
this event. A plugin that ignores crashes can return `:ok` immediately.
A plugin emits an alert with `Kettlecorn.Host.call("emit_alert", fields)`,
where `fields` uses the string keys `"device"`, `"kind"`, and optionally
`"temperature"`. An async Rust callback adds the plugin's filename stem
and writes the alert.

The executable loads the runtime relative to itself. Copy the bundle to run
it on another machine on the same platform:

```sh
cp -RL result-rust-device-monitor device-monitor-bundle
```

The bundle includes the matching platform runtime. The destination machine
can run it without Nix, Cargo, or a host BEAM installation.

### Pulse Field

[Pulse Field](rust/pulse-field/) visualizes BEAM workers moving around a grid
and sending messages. Numbered rings and trails show each worker's movement.
Lines between workers show messages. Rust moves the gold pulses.

```sh
just pulse-field cover
just pulse-field relay
just pulse-field mirrors
just pulse-field prism
just pulse-field sierpinski
```

`just pulse-field` opens Cover by default. The executable embeds the preset
scripts. Pass an `.exs` path to load a script from disk and pick up edits when
you press **R**. Run `just -- pulse-field --help` to list the presets.

Choose **Fixed lanes**, **Sweep**, or **Orbit** and one to four automatic
emitters. Fixed emitters stay in place, sweeping emitters slide along their
edges, and orbiting emitters travel around the perimeter. They share one firing
clock and take turns. Choose **Manual only** to turn off automatic fire.

Click a grid cell to select it and queue a burst from that cell. **Fire burst**
queues another burst from the selected cell. Both use the direction and pulse
count set under **Manual burst**. The first pulse appears on the next tick.

**Space** pauses or resumes playback. **Right Arrow** pauses playback and
advances one frame if the VM is ready. **R** reloads the script in a fresh VM,
clears the canvas, and resumes playback. The selected pattern, emitter count,
and manual burst settings carry over. The automatic sequence starts at tick one.

Press **H** to hide or show the controls, or click **Hide controls** in the
toolbar. Playback and reload shortcuts still work with the controls hidden.

The status bar counts OTP processes directly linked to the Elixir session at
the end of each frame. Workers started with `spawn_link` from `Bot.init/1` or
`Bot.frame/2` count even if they draw only marks, like the Sierpiński row workers.

#### Preset settings

Each preset starts with the settings below. Change them under **Automatic fire**
and press **R** to replay from the first frame with your changes.

| Script | Pattern | Emitters | What to watch |
| --- | --- | ---: | --- |
| [`cover.exs`](rust/pulse-field/cover.exs) | Fixed lanes | 1 | Two workers take turns shielding the same lane. Look for `cover_me` and `in_position` as they swap. |
| [`relay.exs`](rust/pulse-field/relay.exs) | Orbit | 4 | Four workers leave trails on square tracks. The first mirror handoff happens at frame 16. Watch for pulses reflecting off the raised mirror. |
| [`mirrors.exs`](rust/pulse-field/mirrors.exs) | Orbit | 4 | Pulses bounce between cells. Violet marks show fixed mirrors reflecting a pulse, and pink marks show reflections from cells flipped by a neighbor. |
| [`prism.exs`](rust/pulse-field/prism.exs) | Sweep | 4 | Pulses trace the outer square. To see the inner bands, fire a southbound burst from `(20, 8)` or `(20, 14)`. |
| [`sierpinski.exs`](rust/pulse-field/sierpinski.exs) | Sweep | 4 | Sixteen row workers draw a Sierpiński triangle from the top down. Filled cells flash green when a pulse passes through. |

The default [cover script](rust/pulse-field/cover.exs) starts two BEAM workers.
Each worker has three shield charges and two health. A raised shield spends a
charge to absorb a pulse. A pulse that reaches a worker with its shield down
or depleted costs one health. Lowered shields recharge and workers exit at
zero health. Arcs around the worker show charge and dots inside show health.

At one charge, the worker covering a stream can send `:cover_me` to a ready
teammate. The teammate moves into the stream, raises its shield, and replies
`:in_position`. Labels on the message lines show both steps. The first worker
then withdraws to recharge. Edit `@workers` to change the size of the team.

**Try an earlier handoff.** Copy `cover.exs` and run `just pulse-field PATH`
with the copy. Select **Fixed lanes** and one emitter, then watch the first
handoff. Change `@help_at_charge` from `1` to `2`, save, and press **R** to
replay the sequence. At `1`, the second absorbed pulse triggers the request.
At `2`, the first absorbed pulse triggers it.

#### Live-edit the Sierpiński triangle

Copy the script and launch it by path so **R** picks up edits. Select **Sweep**
and **4** emitters to match the preset.

```sh
cp examples/rust/pulse-field/sierpinski.exs /tmp/live-triangle.exs
just pulse-field /tmp/live-triangle.exs
```

The `for` loop in `Bot.init/1` spawns one worker per row. Each worker uses
`Bitwise.band(x, y) == x` to decide which cells to draw. Replace `init/1` with
this version to draw four smaller triangles. Each triangle uses eight row
workers, with successive triangles starting eight frames apart.

```elixir
def init(_board) do
  for {cx, top, delay} <- [{10, 4, 0}, {30, 4, 8}, {10, 22, 16}, {30, 22, 24}],
      y <- 0..7 do
    board_y = top + y

    pid =
      spawn_link(fn ->
        cells =
          for x <- 0..y, Bitwise.band(x, y) == x do
            {cx + 2 * x - y, board_y}
          end

        paint_row(cells, delay + 2 * y)
      end)

    {board_y, pid}
  end
end
```

Save and press **R**. All 32 workers start when the script loads. The delay
controls when each worker starts painting its row.

#### Script interface

Each script defines:

- `Bot.init(board)` receives a map with string keys `"size"` and `"center"`.
  The size is the board's side length in cells. The center is an `{x, y}`
  tuple. The function returns state that stays in Elixir and can contain PIDs.
- `Bot.frame(view, state)` receives a map with string keys `"tick"`,
  `"pulses"`, and `"emitters"`. Each pulse is `{id, {x, y}, {dx, dy}}`.
  Its position is the cell it just entered. Each automatic emitter is
  `{{x, y}, {dx, dy}}`. Coordinates start at zero in the upper left.
  The function returns `{drawing, next_state}`.

The drawing is a map with string keys `"turns"`, `"marks"`, `"actors"`,
`"messages"`, and `"hits"`. Each value is a list, and omitted fields are empty.

- A turn is `{pulse_id, {dx, dy}}` and changes the pulse's movement on the
  next tick. Directions are one-cell cardinal or diagonal steps. A mark is
  `{{x, y}, ink}`. Ink indices `0` through `3` are cyan, violet, pink, and green.
- An actor is `{actor_id, {x, y}, ink, state}`. Use `nil` for a plain actor,
  `:slash` or `:backslash` for a mirror, or `{:shield, raised?, charge, health}`
  for a shield. Keep the actor's integer ID stable across frames so Rust can
  draw a trail from its movement.
- A message is `{sender_id, receiver_id, kind}`. Use `nil` for an unlabeled
  line or `:cover_me` or `:in_position` to label it. The script sends the BEAM
  message and the drawing records it. Rust draws the line when both the
  sender and receiver are listed in that frame's `"actors"`.
- A hit is `{pulse_id, ink, :shield | :damage}`. Rust removes that pulse and
  draws a flash. If the frame includes both a turn and a hit for the same
  pulse, the hit takes precedence.

Each frame has a 500 ms guest call timeout. Marks fade over 72 ticks, and
pulses expire after 240 ticks or when they leave the board.

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
