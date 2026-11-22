defmodule Kettlecorn do
  @moduledoc """
  Run untrusted Elixir and Erlang code on the server inside a WebAssembly sandbox.

  Each VM runs OTP/BEAM with Popcorn's patches as a `wasm32-wasip3`
  component in its own native launcher process with embedded Wasmtime. By default
  the guest has no network, no OS processes, no native code loading and no access to the
  host file system beyond a private copy of the runtime. Memory is capped
  by default; CPU and wall-clock limits are opt-in. See `Kettlecorn.Sandbox`
  for the limits and the opt-in network grants.

      {:ok, vm} = Kettlecorn.start_link(max_fuel: 50_000_000_000, max_lifetime: 30_000)
      {:ok,
       %{
         "value" => [{1, 1}, {2, 4}, {3, 9}],
         "inspected" => "[{1, 1}, {2, 4}, {3, 9}]"
       }} = Kettlecorn.eval(vm, "Enum.map(1..3, fn n -> {n, n * n} end)")

      {:ok, %{"output" => "hi\\n", "value" => :ok}} = Kettlecorn.eval(vm, ~S|IO.puts("hi")|)

      {:error, %{"kind" => "timeout"}} =
        Kettlecorn.eval(vm, "Stream.repeatedly(fn -> 1 end) |> Stream.run()", timeout: 1_000)

      {:ok, %{"value" => 21}} = Kettlecorn.eval(vm, "X = 20. X + 1.", language: :erlang)
      Kettlecorn.stop(vm)

  `max_fuel` bounds total execution in Wasmtime fuel units (roughly WebAssembly
  instructions), and `max_lifetime: 30_000` caps elapsed time at 30 seconds.
  Both limits include startup and apply across all evaluations in the VM.

  `call/4` and `cast/3` reach GenServers in the guest (through the guest's
  `Kettlecorn.Proxy`), and `send/4` delivers `{:wasm, payload}` to a
  guest process. Messages the guest sends with
  `Kettlecorn.Host.send/1` (see the [Guest API guide](guest-api.html))
  arrive in the `:owner` process as
  `{:kettlecorn, vm, {:message, term}}`, decoded by `Kettlecorn.ETF`. A
  `Kettlecorn.Host.call/3` in the guest arrives as
  `{:kettlecorn, vm, {:host_call, reply_to, name, args}}`; answer it with
  `reply/3`. Owners call `acknowledge/2` after handling events to release their
  delivery budget; exceeding that budget stops the VM.

  Payloads sent to the guest must contain only atoms already loaded there;
  its safe decoder rejects unknown atoms. Use strings for application data
  whose labels are not part of the guest code.

  Options are keyword lists with unique keys. Unknown keys and invalid
  option values raise `ArgumentError`.
  """

  alias Kettlecorn.Options
  alias Kettlecorn.Protocol
  alias Kettlecorn.Timeout
  alias Kettlecorn.VM

  require Options

  @type vm :: GenServer.server()

  @typedoc """
  A VM's resource use. `fuel_consumed` counts fuel since the VM started, including
  boot, and is nil when `:max_fuel` is `:infinity`. `memory` is the guest's linear
  memory in bytes; it never shrinks. `rss` is the launcher process's resident set
  size in bytes, on Linux only; it is nil on other systems.
  """
  @type stats :: %{
          fuel_consumed: non_neg_integer() | nil,
          memory: non_neg_integer(),
          rss: non_neg_integer() | nil
        }

  @doc """
  Starts a VM linked to the caller and waits until it has booted.

  Resource limits and guest crashes can terminate the linked caller. Use `start/1`
  with monitoring when the caller must survive VM failures; `:stop_with` ties an
  unlinked VM to a worker's lifetime. See
  [Managing VM lifetime](sandbox.html#managing-vm-lifetime).

  Guest application failures return `{:error, :boot_failed}`. A VM that
  exits during boot or exceeds `:boot_timeout` returns
  `{:error, {:vm_down, reason}}`.

  Accepts the options in `Kettlecorn.Sandbox`, plus:

  #{VM.options_doc()}

  Raises `ArgumentError` for an unknown or invalid option, or a missing or
  incompatible runtime (see `Kettlecorn.Sandbox.new/1`).
  """
  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts \\ []), do: start_vm(&GenServer.start_link/3, opts)

  @doc "Like `start_link/1` but not linked to the caller."
  @spec start(keyword()) :: {:ok, pid()} | {:error, term()}
  def start(opts \\ []), do: start_vm(&GenServer.start/3, opts)

  defp start_vm(start, opts) do
    {vm_opts, sandbox_opts} = VM.split_options!(opts)
    vm_opts = [{:sandbox, Kettlecorn.Sandbox.new(sandbox_opts)} | vm_opts]

    start.(VM, vm_opts, Keyword.put(Keyword.take(opts, [:name]), :timeout, :infinity))
  end

  @eval_schema NimbleOptions.new!(
                 timeout: [
                   type: :timeout,
                   default: 5_000,
                   doc: "Evaluation deadline in milliseconds, or `:infinity`."
                 ],
                 binding: [
                   type_doc: "map or list of variable/value pairs",
                   type:
                     {:or,
                      [
                        {:map, :any, :any},
                        {:list, {:tuple, [:any, :any]}}
                      ]},
                   default: %{},
                   doc: """
                   Variable names mapped to plain values. Names are converted to strings.
                   """
                 ],
                 language: [
                   type: {:in, [:elixir, :erlang]},
                   default: :elixir,
                   doc: "Language of the source code."
                 ]
               )

  @doc """
  Evaluates Elixir or Erlang `code` in the guest.

  Returns `{:ok, map}` with `"inspected"` (the formatted result), `"output"`
  (captured standard output) and, for plain data of at most 1,000,000 terms, `"value"`.
  On failure, returns `{:error, map}` with `"kind"` (`"error"`, `"exit"`,
  `"throw"` or `"timeout"`), `"message"` and `"output"`.

  Writes to stderr bypass evaluation capture and go to the VM's console output.
  They are available through `take_output/1` and, when an `:owner` is configured,
  `{:kettlecorn, vm, {:stderr, data}}` events.

  The evaluator is a GenServer in the guest that `eval/3` reaches with
  `call/4`, so it can also return `call/4`'s errors:

    * `{:error, {:vm_down, reason}}` - the whole VM died.
    * `{:error, :request_queue_full}` - the unanswered request limit was reached;
      the evaluation request was not sent.
    * `{:error, :timeout}` - the proxy received no evaluator reply by
      `:timeout` + #{Timeout.evaluation(0).proxy} milliseconds, or the host received no
      guest reply by `:timeout` + #{Timeout.evaluation(0).host} milliseconds. An evaluator
      that stops the code at `:timeout` and replies returns `"kind" => "timeout"`.
    * `{:error, :noproc}` - the evaluator isn't running (guest code can stop
      it or unregister its name).
    * `{:error, {:exit, inspected_reason}}` - the evaluator exited during
      the call.
    * `{:error, :bad_payload}` or `{:error, :bad_request}` - the guest
      rejected the request, for example because a binding contains an
      atom not loaded in the guest.
    * `{:error, {:bad_reply, term}}` - an answer of another shape (guest code
      can send one in the evaluator's place).

  ## Options

  #{NimbleOptions.docs(@eval_schema)}

  Erlang `code` is either expressions, evaluated one after another like in
  the Erlang shell (`"X = 20. X + 1."`; the last dot is optional), or a
  module, starting with `-module(name).`, which is compiled and loaded and
  returns `{:module, name}`. Bindings use Erlang variable names
  (`binding: %{"N" => 21}`). Results and error messages use Erlang syntax.

  The guest keeps up to 1,000,000 bytes of output, ending at a UTF-8 boundary;
  `"output_truncated"` is `true` when there was more. Processes started by
  the code keep running after success. On timeout, the evaluator
  attempts to kill them through tracing, which guest code can disable. Use
  VM limits to bound untrusted code.
  """
  @spec eval(vm(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def eval(vm, code, opts \\ []) when is_binary(code) do
    opts = Options.validate!(opts, @eval_schema)
    timeouts = Timeout.evaluation(opts[:timeout])
    binding = Map.new(opts[:binding], fn {k, v} -> {to_string(k), v} end)
    language = Atom.to_string(opts[:language])

    request =
      {:eval, code,
       %{
         "timeout_ms" => timeouts.evaluation,
         "finish_timeout_ms" => timeouts.finish,
         "binding" => binding,
         "language" => language
       }}

    case guest_call(vm, "kettlecorn_evaluator", request, timeouts) do
      {:ok, {:ok, result}} -> {:ok, result}
      {:ok, {:error, error}} -> {:error, error}
      {:ok, other} -> {:error, {:bad_reply, other}}
      {:error, _} = error -> error
    end
  end

  @doc """
  Calls a GenServer registered as `target` in the guest, like `GenServer.call/3`.

  Returns `{:ok, reply}` or `{:error, reason}`. Common reasons are `:noproc`,
  `:timeout`, `:request_queue_full`, `{:exit, inspected_reason}` and `{:vm_down, reason}`.
  `:request_queue_full` means the VM's unanswered request limit was reached;
  the request was not sent.
  The guest can reject delivery with `:bad_payload` or `:bad_request`;
  a malformed proxy reply returns `{:bad_reply, term}`.
  After `timeout`, the host allows another #{Timeout.request(0).host} milliseconds
  for the guest's timeout reply.
  """
  @spec call(vm(), atom() | String.t(), term(), timeout()) :: {:ok, term()} | {:error, term()}
  def call(vm, target, request, timeout \\ 5_000) do
    guest_call(vm, name!(target), request, Timeout.request(timeout!(timeout)))
  end

  defp guest_call(vm, target, request, timeouts) do
    prepared = Protocol.prepare_call(target, request, timeouts.proxy)
    GenServer.call(vm, {:request, :call, nil, prepared, timeouts.host}, :infinity)
  catch
    :exit, reason -> {:error, {:vm_down, reason}}
  end

  @doc """
  Casts `request` to a GenServer registered as `target` in the guest.
  Returns `:ok` without confirming delivery.
  """
  @spec cast(vm(), atom() | String.t(), term()) :: :ok
  def cast(vm, target, request) do
    prepared = Protocol.prepare_cast(name!(target), request)
    GenServer.cast(vm, {:send, prepared})
  end

  @doc """
  Sends `{:wasm, payload}` to a guest process: a registered name or a
  `Kettlecorn.Pid` received from the guest.

  Unlike `Kernel.send/2`, reports whether the target existed: `:ok`, or
  `{:error, reason}` with `:noproc`, `:bad_payload`, `:bad_request`,
  `:request_queue_full` (rejected before transmission),
  `:timeout` (no answer within `timeout` plus #{Timeout.request(0).host} milliseconds)
  or `{:vm_down, reason}`. A handle from another VM returns `{:error, :wrong_vm}`.
  """
  @spec send(vm(), atom() | String.t() | Kettlecorn.Pid.t(), term(), timeout()) ::
          :ok | {:error, :noproc | :bad_payload | :bad_request | :timeout | term()}
  def send(vm, target, payload, timeout \\ 5_000) do
    {origin, target} = target!(target)
    deadline = Timeout.request(timeout!(timeout)).host
    prepared = Protocol.prepare(target, payload)
    GenServer.call(vm, {:request, :send, origin, prepared, deadline}, :infinity)
  catch
    :exit, reason -> {:error, {:vm_down, reason}}
  end

  defp timeout!(:infinity), do: :infinity
  defp timeout!(timeout) when is_integer(timeout) and timeout >= 0, do: timeout
  defp timeout!(timeout), do: raise(ArgumentError, "invalid timeout: #{inspect(timeout)}")

  defp target!(%Kettlecorn.Pid{vm: vm, etf: etf} = pid) when is_pid(vm) and is_binary(etf),
    do: {vm, pid}

  defp target!(%Kettlecorn.Pid{}), do: raise(ArgumentError, "guest PID has no originating VM")
  defp target!(target), do: {nil, name!(target)}

  defp name!(name) when Options.is_name(name), do: to_string(name)

  defp name!(%Kettlecorn.Pid{} = pid) do
    raise ArgumentError,
          "a guest target is a registered name (an atom or a non-empty string); " <>
            "only send/4 takes a Kettlecorn.Pid, got: #{inspect(pid)}"
  end

  defp name!(name) do
    raise ArgumentError,
          "a guest target is a registered name (an atom or a non-empty string), got: #{inspect(name)}"
  end

  @doc """
  Replies to a guest's `Kettlecorn.Host.call/3` using the `reply_to` from its
  `{:host_call, reply_to, name, args}` event. `result` is `{:ok, value}` or
  `{:error, binary_reason}`; the guest's call returns it.

  Error reasons are binaries, so the guest can distinguish host errors from
  its own `{:error, :timeout}`.

  Returns `:ok` without confirming delivery. Replies containing atoms not
  loaded in the guest are rejected, so the call can time out.
  """
  @spec reply(vm(), binary(), {:ok, term()} | {:error, String.t()}) :: :ok
  def reply(vm, reply_to, {:ok, _value} = result),
    do: GenServer.cast(vm, {:send, Protocol.prepare_reply(reply_to, result)})

  def reply(vm, reply_to, {:error, reason} = result) when is_binary(reason),
    do: GenServer.cast(vm, {:send, Protocol.prepare_reply(reply_to, result)})

  @doc "Writes `data` to the guest's standard input."
  @spec write_stdin(vm(), iodata()) :: :ok
  def write_stdin(vm, data),
    do: GenServer.cast(vm, {:frame, data |> Protocol.stdin_frame() |> Protocol.frame()})

  @doc """
  Signals the end of the guest's standard input.
  Readers get `:eof` after consuming all queued bytes.
  """
  @spec close_stdin(vm()) :: :ok
  def close_stdin(vm),
    do: GenServer.cast(vm, {:frame, Protocol.frame(Protocol.stdin_eof_frame())})

  @doc """
  Acknowledges `count` owner events after handling them, releasing their delivery
  budget. Only the VM's owner can acknowledge events. A count larger than the
  number outstanding acknowledges all current events; the excess is ignored.
  Event delivery preserves order.
  """
  @spec acknowledge(vm(), pos_integer()) :: :ok
  def acknowledge(vm, count \\ 1)

  def acknowledge(vm, count) when is_integer(count) and count > 0,
    do: GenServer.cast(vm, {:acknowledge, self(), count})

  def acknowledge(_vm, _count), do: raise(ArgumentError, "event count must be a positive integer")

  @doc """
  Returns and clears the guest console output buffered since the last call.

  The buffer combines console stdout and stderr without stream labels. Standard
  output captured in an `eval/3` result is excluded. Configure an `:owner` to
  receive separate `:stdout` and `:stderr` events.
  """
  @spec take_output(vm()) :: binary()
  def take_output(vm), do: GenServer.call(vm, :take_output)

  @doc """
  Returns the VM's resource use. See `t:stats/0`.

  The launcher samples fuel when the guest calls the host and at epoch
  checks, which run at 10 ms intervals. After `eval/3` or `call/4` returns,
  the sample includes work up to the reply. On shutdown the owner receives
  `{:kettlecorn, vm, {:stopped, stats}}`. The stats are `nil` if the launcher
  exits without reporting them. See
  [Measuring resource use](sandbox.html#measuring-resource-use).
  """
  @spec stats(vm()) :: {:ok, stats()} | {:error, term()}
  def stats(vm) do
    {instance, os_pid} = GenServer.call(vm, :stats_source)
    VM.Stats.read(instance, os_pid)
  end

  @doc "Stops the VM and its launcher process."
  @spec stop(vm()) :: :ok
  def stop(vm) do
    GenServer.stop(vm, :normal)
  catch
    :exit, _ -> :ok
  end

  @doc """
  Evaluates `code` in a fresh VM and stops it afterward.

  Accepts the options of both `start_link/1` and `eval/3`. Use this when
  each piece of code must not see state left behind by others.
  """
  @spec run(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(code, opts \\ []) do
    {eval_opts, vm_opts} = Keyword.split(opts, Keyword.keys(@eval_schema.schema))

    case start(Keyword.put(vm_opts, :stop_with, self())) do
      {:ok, vm} ->
        try do
          eval(vm, code, eval_opts)
        after
          stop(vm)
        end

      error ->
        error
    end
  end
end
