defmodule Kettlecorn.VM do
  @moduledoc """
  One sandboxed BEAM instance running in Wasmtime.

  The bundled native launcher embeds Wasmtime and owns the guest.
  This GenServer owns the launcher through an Erlang port for input and process
  lifecycle. Guest output arrives over a private local socket in records capped
  at 64 KiB. Delivery is re-armed after each record is processed, bounding raw
  bytes awaiting processing independently of owner event budgets.

  The guest protocol uses length-prefixed frames (`PROTOCOL.md` in the repository):

    * guest console output (`IO.puts/1` etc.) arrives as `:stdout`/`:stderr` frames,
    * `:wasm.send/1` in the guest arrives as a `:message` frame (ETF),
    * the host delivers messages to guest processes with `:send` frames.

  If the port dies (the guest crashed, ran out of memory, hit the wall-clock
  limit, or was killed) every pending request fails with
  `{:error, {:vm_down, reason}}` and this process stops. A guest frame longer
  than `:max_message_size` (default 64 MiB) also stops the VM, with reason
  `{:vm_down, {:frame_too_large, length}}`.

  Use the public API in `Kettlecorn`.
  """
  use GenServer
  require Logger

  alias Kettlecorn.Events
  alias Kettlecorn.Options
  alias Kettlecorn.Protocol
  alias Kettlecorn.Sandbox.Instance
  alias Kettlecorn.VM.Output
  alias Kettlecorn.VM.Requests
  alias Kettlecorn.VM.Termination

  @options_schema NimbleOptions.new!(
                    owner: [
                      type: {:or, [:pid, nil]},
                      default: nil,
                      doc: """
                      PID that receives `{:kettlecorn, vm_pid, event}` for console output (`{:stdout,
                      data}`, `{:stderr, data}`), messages (`{:message, term}`) and host calls
                      (`{:host_call, reply_to, name, args}`), and, with preloading enabled, modules loaded on demand (`{:late_load, "Elixir.Mod"}`). Acknowledge events with
                      `Kettlecorn.acknowledge/2` after handling them. When a started VM stops,
                      the owner receives `{:stopped, stats}` once, with the final
                      `Kettlecorn.stats/1` values and `rss: nil`, or `stats: nil` if the
                      launcher exited without reporting them. It needs no acknowledgement.
                      Standard output captured by `Kettlecorn.eval/3` appears in its
                      result; writes to stderr arrive as console events.
                      """
                    ],
                    boot_timeout: [
                      type: :pos_integer,
                      default: 30_000,
                      doc: "Milliseconds to wait for the VM to boot."
                    ],
                    output_limit: [
                      type: :non_neg_integer,
                      default: 1_048_576,
                      doc: """
                      Bytes of guest console output buffered for `take_output/1`. Output beyond the cap is
                      not buffered; owner delivery is subject to the pending event budgets.
                      """
                    ],
                    max_message_size: [
                      type: :pos_integer,
                      default: 64 * 1024 * 1024,
                      doc: """
                      Longest guest frame in bytes. A longer frame kills the VM with `{:vm_down,
                      {:frame_too_large, length}}`. Also sets the decoder's memory budget (retained
                      binaries plus estimated heap space); messages exceeding that budget are
                      dropped. See `Kettlecorn.ETF`.
                      """
                    ],
                    max_pending_requests: [
                      type: :pos_integer,
                      default: 1_024,
                      doc: """
                      Maximum unanswered requests. Excess requests return `{:error, :request_queue_full}`
                      before transmission. Caller exit releases a request without cancelling guest work.
                      """
                    ],
                    max_pending_events: [
                      type: :pos_integer,
                      default: 1_024,
                      doc:
                        "Maximum unacknowledged owner events. Overflow stops the VM with `:event_queue_full`."
                    ],
                    max_pending_event_bytes: [
                      type: :pos_integer,
                      default: 64 * 1024 * 1024,
                      doc:
                        "Estimated retained-byte budget for unacknowledged owner events. Use `Kettlecorn.acknowledge/2` after handling them."
                    ],
                    stop_with: [
                      type: :pid,
                      doc: """
                      The VM stops when this process exits. `run/2` uses it to keep its VM from outliving
                      the caller.
                      """
                    ],
                    name: [type: :any, doc: "GenServer name."]
                  )

  @doc false
  def options_doc, do: NimbleOptions.docs(@options_schema)

  @doc false
  def split_options!(opts) do
    {vm_opts, sandbox_opts} = Keyword.split(opts, Keyword.keys(@options_schema.schema))
    {Options.validate!(vm_opts, @options_schema), sandbox_opts}
  end

  defstruct [
    :port,
    :owner,
    :output_limit,
    :max_message_size,
    :instance,
    :stop_with,
    :events,
    :output_transport,
    exit_status: nil,
    termination: nil,
    failure: nil,
    input: :queue.new(),
    input_bytes: 0,
    boot: :booting,
    frame_decoder: {:header, ""},
    requests: %Requests{},
    output: [],
    output_size: 0,
    fatal: nil
  ]

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    try do
      opts |> Keyword.fetch!(:sandbox) |> Instance.prepare()
    rescue
      e -> {:error, {:prepare_failed, Exception.message(e)}}
    else
      instance ->
        with {:ok, state} <- start_port(instance, opts),
             {:ok, state} <- boot(state, Keyword.fetch!(opts, :boot_timeout)) do
          {:ok, state}
        else
          {:error, reason, resource} ->
            # GenServer does not call terminate/2 when init/1 fails.
            cleanup(resource)
            {:error, reason}
        end
    end
  end

  defp start_port(instance, opts) do
    launch_port(instance, opts, Output.prepare!())
  rescue
    e -> {:error, {:start_failed, Exception.message(e)}, instance}
  end

  defp launch_port(instance, opts, output) do
    [executable | args] = Instance.command(instance)
    args = ["--output-socket", Output.path(output) | args]
    stop_with = opts[:stop_with]
    if stop_with, do: Process.monitor(stop_with)
    max_lifetime = instance.sandbox.max_lifetime

    # Wasmtime enforces this limit; the host timer is a backstop.
    if max_lifetime != :infinity,
      do: Process.send_after(self(), :max_lifetime, max_lifetime + 2_000)

    port =
      Port.open(
        {:spawn_executable, executable},
        [
          :binary,
          :exit_status,
          :use_stdio,
          args: args
        ]
      )

    state = %__MODULE__{
      port: port,
      output_transport: output,
      owner: Keyword.get(opts, :owner),
      instance: instance,
      stop_with: stop_with,
      events: Events.new(opts[:max_pending_events], opts[:max_pending_event_bytes]),
      requests: Requests.new(Keyword.fetch!(opts, :max_pending_requests)),
      output_limit: Keyword.fetch!(opts, :output_limit),
      max_message_size: Keyword.fetch!(opts, :max_message_size)
    }

    {:ok, state}
  rescue
    e ->
      Output.cleanup(output)
      {:error, {:start_failed, Exception.message(e)}, instance}
  end

  defp boot(state, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout

    case await_boot(state, deadline) do
      {:ok, state} ->
        {:ok, state}

      {:stop, reason, state} ->
        {:error, startup_reason(reason), state}
    end
  end

  defp await_boot(%{boot: :ready} = state, _deadline), do: {:ok, state}
  defp await_boot(%{boot: :failed} = state, _deadline), do: {:stop, :boot_failed, state}

  defp await_boot(state, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:stop, {:vm_down, :boot_timeout}, state}
    else
      # Wait in init/1 so start_link/1 returns boot failures as startup errors.
      # Leave queued calls in the mailbox until initialization completes.
      receive do
        {port, _event} = message when port == state.port ->
          boot_message(message, state, deadline)

        {event, socket, _data} = message
        when event in [:tcp, :tcp_error] and socket == state.output_transport.socket ->
          boot_message(message, state, deadline)

        {:tcp_closed, socket} = message when socket == state.output_transport.socket ->
          boot_message(message, state, deadline)

        {:DOWN, _ref, :process, pid, _reason} = message when pid == state.stop_with ->
          boot_message(message, state, deadline)

        :max_lifetime ->
          boot_message(:max_lifetime, state, deadline)

        {:EXIT, port, _reason} when port == state.port ->
          await_boot(state, deadline)

        {:EXIT, pid, reason} when is_pid(pid) ->
          {:stop, reason, state}
      after
        remaining -> {:stop, {:vm_down, :boot_timeout}, state}
      end
    end
  end

  defp boot_message(message, state, deadline) do
    case handle_info(message, state) do
      {:noreply, state} -> await_boot(state, deadline)
      {:stop, _reason, _state} = stopped -> stopped
    end
  end

  defp startup_reason({:shutdown, reason}), do: reason
  defp startup_reason(reason), do: reason

  @impl true
  def handle_call({:request, _kind, origin, _prepared, _timeout}, _from, state)
      when origin != nil and origin != self(),
      do: {:reply, {:error, :wrong_vm}, state}

  def handle_call({:request, kind, _origin, prepared, timeout}, from, state) do
    case Requests.admit(state.requests, kind, from, timeout) do
      {:ok, id, requests} ->
        continue(command(%{state | requests: requests}, Protocol.send_frame(id, prepared)))

      :full ->
        {:reply, {:error, :request_queue_full}, state}
    end
  end

  def handle_call(:stats_source, _from, state) do
    os_pid =
      case state.port && Port.info(state.port, :os_pid) do
        {:os_pid, os_pid} -> os_pid
        _ -> nil
      end

    {:reply, {state.instance, os_pid}, state}
  end

  def handle_call(:take_output, _from, state) do
    output = state.output |> Enum.reverse() |> IO.iodata_to_binary()
    {:reply, output, %{state | output: [], output_size: 0}}
  end

  @impl true
  def handle_cast({:send, prepared}, state) do
    {id, state} = next_id(state)
    continue(command(state, Protocol.send_frame(id, prepared)))
  end

  def handle_cast({:acknowledge, owner, count}, %{owner: owner} = state) do
    {:noreply, %{state | events: Events.acknowledge(state.events, count)}}
  end

  def handle_cast({:acknowledge, _owner, _count}, state), do: {:noreply, state}

  def handle_cast({:frame, frame}, state) do
    continue(write_frame(state, frame))
  end

  @impl true
  def handle_info(
        {port, {:data, <<0>>}},
        %{port: port, output_transport: %{socket: nil}} = state
      ) do
    case Output.connect(state.output_transport) do
      {:ok, output} -> {:noreply, %{state | output_transport: output}}
      {:error, reason} -> down(state, {:output_connect, reason})
    end
  end

  def handle_info({port, {:data, _data}}, %{port: port} = state),
    do: down(state, :unexpected_launcher_output)

  def handle_info({:tcp, socket, data}, %{output_transport: %{socket: socket}} = state) do
    case Protocol.split(data, state.max_message_size, state.frame_decoder) do
      {:ok, frames, decoder} ->
        max = state.max_message_size

        state = Enum.reduce_while(frames, state, &consume_frame(&1, &2, max))

        demand_output(%{state | frame_decoder: decoder})

      {:error, reason} ->
        down(state, reason)
    end
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state),
    do: finish_output(%{state | port: nil, exit_status: status})

  def handle_info({:tcp_closed, socket}, %{output_transport: %{socket: socket}} = state),
    do: finish_output(%{state | output_transport: %{state.output_transport | socket: nil}})

  def handle_info({:tcp_error, socket, reason}, %{output_transport: %{socket: socket}} = state),
    do: down(state, {:output_read, reason})

  def handle_info(:flush_input, state),
    do: continue(flush_input(state))

  def handle_info(:max_lifetime, state), do: down(state, :timeout)

  def handle_info({:deadline, id, monitor}, state),
    do: {:noreply, %{state | requests: Requests.expire(state.requests, id, monitor)}}

  def handle_info({:DOWN, _ref, :process, pid, _reason}, %{stop_with: pid} = state),
    do: {:stop, :normal, state}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state),
    do: {:noreply, %{state | requests: Requests.caller_down(state.requests, ref)}}

  def handle_info({:EXIT, _port, _reason}, state), do: {:noreply, state}

  defp demand_output(%{failure: nil} = state) do
    case Output.next(state.output_transport) do
      :ok -> continue(state)
      {:error, reason} -> down(state, {:output_read, reason})
    end
  end

  defp demand_output(state), do: continue(state)

  defp consume_frame(frame, state, max) do
    {event, size} = Protocol.decode(frame, max, self())
    state = handle_frame(event, state, size)
    if state.failure, do: {:halt, state}, else: {:cont, state}
  end

  defp down(state, reason),
    do: {:stop, {:shutdown, {:vm_down, reason}}, fail_all(state, {:vm_down, reason})}

  defp finish_output(%{exit_status: status, output_transport: %{socket: nil}} = state)
       when status != nil do
    state = %{state | termination: Termination.read(state.instance)}
    down(state, down_reason(status, state))
  end

  defp finish_output(state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state), do: cleanup(state, true)

  defp cleanup(%Instance{} = instance), do: Instance.cleanup(instance)
  defp cleanup(%__MODULE__{} = state), do: cleanup(state, false)

  defp cleanup(state, report_stopped?) do
    Output.cleanup(state.output_transport)

    {confirmed, termination} = stop_launcher(state)
    if report_stopped?, do: report_stopped(state, termination)

    if confirmed do
      cleanup(state.instance)
    else
      Logger.error("kettlecorn: launcher did not confirm shutdown; kept #{state.instance.dir}")
    end
  end

  # The launcher has exited: the record, if any, is final.
  defp stop_launcher(%__MODULE__{port: nil, termination: nil} = state),
    do: {true, Termination.read(state.instance)}

  defp stop_launcher(%__MODULE__{port: nil} = state), do: {true, state.termination}

  defp stop_launcher(state) do
    # Normal port closure flushes queued input, which a stalled launcher may never read.
    :erlang.exit(state.port, :kill)

    case Termination.await(state.instance, System.monotonic_time(:millisecond) + 5_000) do
      {:ok, termination} -> {true, termination}
      :timeout -> {false, %{outcome: nil, stats: nil}}
    end
  end

  defp report_stopped(%{owner: nil}, _termination), do: :ok

  defp report_stopped(state, %{stats: stats}),
    do: send(state.owner, {:kettlecorn, self(), {:stopped, stats}})

  defp handle_frame({:stdout, data}, state, size), do: buffer_output(:stdout, data, state, size)
  defp handle_frame({:stderr, data}, state, size), do: buffer_output(:stderr, data, state, size)
  defp handle_frame({:fatal, text}, state, _size), do: %{state | fatal: text}

  defp handle_frame({:send_result, id, result}, state, _size) do
    case Requests.kind(state.requests, id) do
      :send -> reply(state, id, result)
      # The proxy answers a call that reached it; a failed send fails it here.
      :call when result != :ok -> reply(state, id, result)
      _ -> state
    end
  end

  defp handle_frame({:message, data}, state, size), do: notify(state, {:message, data}, size)

  defp handle_frame({:host_call, reply_to, name, args}, state, size) do
    if state.owner,
      do: notify(state, {:host_call, reply_to, name, args}, size),
      else: reply_to_guest(state, reply_to, {:error, "no host handler"})
  end

  defp handle_frame({:late_load, module}, state, size) do
    if state.owner do
      notify(state, {:late_load, module}, size)
    else
      Logger.warning("kettlecorn: #{inspect(module)} was loaded after preload")
      state
    end
  end

  defp handle_frame(:boot_ready, %{boot: :booting} = state, _size),
    do: %{state | boot: :ready}

  defp handle_frame(:boot_failed, %{boot: :booting} = state, _size),
    do: %{state | boot: :failed}

  defp handle_frame({:proxy_reply, id, result}, state, _size) do
    case Requests.kind(state.requests, id) do
      :call -> reply(state, id, result)
      _ -> state
    end
  end

  defp handle_frame({:error, reason}, state, _size) do
    Logger.warning(
      "kettlecorn: dropping a guest message: #{inspect(reason, limit: 20, printable_limit: 200)}"
    )

    state
  end

  defp handle_frame(event, state, _size) when event in [:boot_ready, :boot_failed, :unknown],
    do: state

  defp reply_to_guest(state, reply_to, result) do
    {id, state} = next_id(state)
    command(state, Protocol.send_frame(id, Protocol.prepare_reply(reply_to, result)))
  end

  defp command(state, body), do: write_frame(state, Protocol.frame(body))

  defp write_frame(%{port: nil} = state, _frame), do: state

  defp write_frame(state, frame) do
    size = :erlang.iolist_size(frame)

    if state.input_bytes + size > Protocol.max_input_size() + 4 or
         :queue.len(state.input) >= 1_024 do
      %{state | failure: :input_queue_full}
    else
      queued = %{
        state
        | input: :queue.in(frame, state.input),
          input_bytes: state.input_bytes + size
      }

      if :queue.is_empty(state.input), do: flush_input(queued), else: queued
    end
  end

  defp flush_input(%{port: nil} = state), do: state

  defp flush_input(state) do
    case :queue.out(state.input) do
      {:empty, _input} ->
        state

      {{:value, frame}, input} ->
        # Suspending on a busy port would prevent the VM from handling shutdown.
        case :erlang.send(state.port, {self(), {:command, frame}}, [:nosuspend]) do
          :ok ->
            flush_input(%{
              state
              | input: input,
                input_bytes: state.input_bytes - :erlang.iolist_size(frame)
            })

          :nosuspend ->
            Process.send_after(self(), :flush_input, 1)
            state
        end
    end
  end

  defp continue(%{failure: nil} = state), do: {:noreply, state}
  defp continue(state), do: down(state, state.failure)

  defp reply(state, id, result),
    do: %{state | requests: Requests.reply(state.requests, id, result)}

  defp buffer_output(stream, data, state, cost) do
    state = notify(state, {stream, data}, cost)
    size = min(byte_size(data), state.output_limit - state.output_size)

    if size == 0 do
      state
    else
      # A slice would retain the entire input binary, even past the output cap.
      kept = :binary.copy(binary_part(data, 0, size))
      %{state | output: [kept | state.output], output_size: state.output_size + size}
    end
  end

  defp notify(%{owner: nil} = state, _event, _size), do: state

  defp notify(state, event, size) do
    case Events.push(state.events, size) do
      {:ok, events} ->
        send(state.owner, {:kettlecorn, self(), event})
        %{state | events: events}

      :full ->
        %{state | failure: :event_queue_full}
    end
  end

  defp next_id(state) do
    {id, requests} = Requests.next_id(state.requests)
    {id, %{state | requests: requests}}
  end

  defp down_reason(_status, %{fatal: fatal}) when fatal != nil, do: {:fatal, fatal}

  defp down_reason(status, state) do
    case state.termination.outcome do
      :timeout -> :timeout
      :out_of_fuel -> :out_of_fuel
      :cancelled -> :normal
      {:exited, code} -> exit_reason(code, state)
      _failed_or_missing -> exit_reason(status, state)
    end
  end

  defp exit_reason(0, _state), do: :normal

  defp exit_reason(status, state) do
    stderr =
      case File.open(
             Instance.stderr_file(state.instance),
             [:read, :binary],
             &IO.binread(&1, 4096)
           ) do
        {:ok, text} when is_binary(text) -> text
        _ -> ""
      end

    {:exit_status, status, stderr}
  end

  defp fail_all(state, reason) do
    %{state | requests: Requests.fail_all(state.requests, reason)}
  end
end
