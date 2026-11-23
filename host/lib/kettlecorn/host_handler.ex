defmodule Kettlecorn.HostHandler do
  @moduledoc """
  A behaviour for handling a VM's host calls in one process with shared state.

  Pass `handler: {module, arg}` to `Kettlecorn.start_link/1`. The VM starts
  a process linked to it that calls `c:init/1` with `arg`, then
  runs `c:handle_host_call/4` serially for calls the VM accepts.
  Return `{:reply, result, state}` to answer at once, or `{:noreply, state}`
  and answer later, from this or another process, with `reply/2`. If the
  process exits, the VM stops.

      defmodule Counter do
        @behaviour Kettlecorn.HostHandler

        @impl true
        def init(start), do: {:ok, start}

        @impl true
        def handle_host_call("next", _args, _from, n), do: {:reply, {:ok, n}, n + 1}
        def handle_host_call(_name, _args, _from, n), do: {:reply, {:error, "unknown"}, n}
      end

      {:ok, vm} = Kettlecorn.start_link(handler: {Counter, 1})

  Queued, running, and deferred calls count toward `:max_host_calls`.
  Cancellation removes a queued call immediately. A cancelled call keeps
  its slot while its callback runs. If the callback has deferred the reply
  or returns `{:noreply, state}`, the slot is released after
  `c:handle_cancel/2` returns. The VM drops replies to cancelled calls.

  Return `{:ok, value}` or `{:error, binary}` as the result. The VM logs
  invalid results and sends `{:error, "invalid host function result"}`.
  Oversized replies yield `{:error, "host reply too large"}`.
  """

  @typedoc "Call identifier for `reply/2`."
  @opaque from :: {pid(), non_neg_integer(), binary()}

  @type result :: {:ok, term()} | {:error, String.t()}

  @callback init(arg :: term()) :: {:ok, state :: term()} | {:stop, reason :: term()}

  @callback handle_host_call(name :: String.t(), args :: map(), from(), state :: term()) ::
              {:reply, result(), state :: term()} | {:noreply, state :: term()}

  @doc "Handles cancellation of a deferred call. The default does nothing."
  @callback handle_cancel(from(), state :: term()) :: {:noreply, state :: term()}

  @doc "Handles other messages sent to the handler. The default drops them."
  @callback handle_info(message :: term(), state :: term()) :: {:noreply, state :: term()}

  @optional_callbacks handle_cancel: 2, handle_info: 2

  alias Kettlecorn.VM.HostCalls

  @doc """
  Answers the call identified by `from`, from any process. A reply to a
  call that was answered or cancelled is dropped.
  """
  @spec reply(from(), result()) :: :ok
  def reply(from, result), do: HostCalls.send_handler_reply(from, result)
end
