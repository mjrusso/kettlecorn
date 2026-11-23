defmodule Kettlecorn.VM.HostCalls do
  @moduledoc false
  require Logger

  alias Kettlecorn.HostHandler.Server
  alias Kettlecorn.Protocol

  # Guest tokens can be reused before a cancellation callback returns.
  # Match replies by host-generated ID so a late reply can't reach a new call.
  # Keep the handler busy until it acknowledges the callback, even if reply/2
  # already removed the call.
  defstruct functions: nil,
            handler: nil,
            max: 4,
            calls: %{},
            tokens: %{},
            queue: :queue.new(),
            busy: nil,
            next_id: 0

  def new(opts) do
    %__MODULE__{functions: opts[:handlers], max: Keyword.fetch!(opts, :max_host_calls)}
  end

  def start_handler(%__MODULE__{} = calls, nil), do: {:ok, calls}

  def start_handler(%__MODULE__{} = calls, {module, arg}) do
    with {:ok, pid} <- Server.start_link(module, arg),
         do: {:ok, %{calls | handler: pid}}
  end

  def owner?(%__MODULE__{functions: nil, handler: nil}), do: true
  def owner?(%__MODULE__{}), do: false

  # Kettlecorn.reply/3, for owners. Encoding in the caller keeps an
  # oversized reply from stopping the VM.
  def send_reply(vm, reply_to, result),
    do: GenServer.cast(vm, {:host_reply, reply_to, Protocol.prepare_reply(reply_to, result)})

  def send_handler_reply({vm, id, token}, result),
    do: GenServer.cast(vm, {:host_calls, {:reply, id, prepare(token, result, nil)}})

  def prepare(token, result, name) do
    result =
      case result do
        {:ok, _value} ->
          result

        {:error, reason} when is_binary(reason) ->
          result

        other ->
          Logger.error("kettlecorn: invalid host call result#{for_name(name)}: #{inspect(other)}")
          {:error, "invalid host function result"}
      end

    try do
      Protocol.prepare_reply(token, result)
    rescue
      ArgumentError -> Protocol.prepare_reply(token, {:error, "host reply too large"})
    end
  end

  defp for_name(nil), do: ""
  defp for_name(name), do: " for #{inspect(name)}"

  def call(%__MODULE__{} = calls, vm, token, name, args) do
    cond do
      # A reply to the second call would reach the first call's caller.
      is_map_key(calls.tokens, token) ->
        {[], calls}

      map_size(calls.calls) >= calls.max ->
        {[prepare(token, {:error, "host call capacity exhausted"}, nil)], calls}

      calls.handler ->
        {id, calls} = add(calls, token, {:queued, name, args})
        {[], dispatch(%{calls | queue: :queue.in({:call, id}, calls.queue)}, vm)}

      function = Map.get(calls.functions, name) ->
        {id, calls} = add(calls, token, nil)
        {[], put(calls, id, start_task(vm, id, token, name, function, args))}

      true ->
        {[prepare(token, {:error, "no host handler"}, nil)], calls}
    end
  end

  # Drop malformed requests that reuse a live token, just as in call/5.
  def reject(%__MODULE__{} = calls, token) do
    if is_map_key(calls.tokens, token),
      do: [],
      else: [prepare(token, {:error, "invalid or oversized host call arguments"}, nil)]
  end

  def handle(%__MODULE__{busy: {:cancel, id}} = calls, vm, :cancel_ack),
    do: {[], dispatch(%{calls | calls: Map.delete(calls.calls, id), busy: nil}, vm)}

  def handle(%__MODULE__{} = calls, _vm, :cancel_ack), do: {[], calls}

  def handle(%__MODULE__{} = calls, _vm, {:result, id, reply}) do
    case calls.calls do
      %{^id => {_token, {:task, _pid, monitor}}} ->
        Process.demonitor(monitor, [:flush])
        {[reply], remove(calls, id)}

      _ ->
        {[], calls}
    end
  end

  def handle(%__MODULE__{busy: {:call, id}} = calls, vm, {:ack, id, reply}) do
    {replies, calls} =
      case {calls.calls[id], reply} do
        {{_token, :running}, :noreply} ->
          {[], put(calls, id, :deferred)}

        {{_token, :running}, reply} ->
          {[reply], remove(calls, id)}

        {{_token, :cancelled}, :noreply} ->
          {[], notify_cancel(calls, id)}

        {{_token, :cancelled}, _reply} ->
          {[], remove(calls, id)}

        # Answered with reply/2 before the callback returned.
        {nil, _reply} ->
          {[], calls}
      end

    {replies, dispatch(%{calls | busy: nil}, vm)}
  end

  def handle(%__MODULE__{} = calls, _vm, {:ack, _id, _reply}), do: {[], calls}

  def handle(%__MODULE__{} = calls, _vm, {:reply, id, reply}) do
    case calls.calls do
      %{^id => {_token, status}} when status in [:running, :deferred] ->
        {[reply], remove(calls, id)}

      _ ->
        {[], calls}
    end
  end

  def down(%__MODULE__{} = calls, monitor, reason) do
    case Enum.find(calls.calls, &match?({_id, {_token, {:task, _pid, ^monitor}}}, &1)) do
      {id, {token, _status}} ->
        Logger.error("kettlecorn: a host function exited: #{inspect(reason)}")
        {[prepare(token, {:error, "host function failed"}, nil)], remove(calls, id)}

      nil ->
        :error
    end
  end

  def cancel(%__MODULE__{} = calls, vm, token) do
    case Map.fetch(calls.tokens, token) do
      {:ok, id} -> cancel_call(calls, vm, id)
      :error -> calls
    end
  end

  defp cancel_call(calls, vm, id) do
    case calls.calls[id] do
      {_token, {:queued, _name, _args}} ->
        %{remove(calls, id) | queue: :queue.delete({:call, id}, calls.queue)}

      {_token, {:task, pid, monitor}} ->
        stop_task(pid, monitor)
        remove(calls, id)

      {_token, :running} ->
        put(calls, id, :cancelled)

      {_token, :cancelled} ->
        calls

      {_token, :deferred} ->
        calls |> notify_cancel(id) |> dispatch(vm)
    end
  end

  # Linked processes outlive a VM that stops normally.
  def stop(%__MODULE__{} = calls) do
    for {_id, {_token, {:task, pid, monitor}}} <- calls.calls, do: stop_task(pid, monitor)

    if calls.handler do
      Process.unlink(calls.handler)
      Process.exit(calls.handler, :shutdown)
    end

    :ok
  end

  defp add(calls, token, status) do
    id = calls.next_id

    calls = %{
      calls
      | calls: Map.put(calls.calls, id, {token, status}),
        tokens: Map.put(calls.tokens, token, id),
        next_id: id + 1
    }

    {id, calls}
  end

  defp put(calls, id, status) do
    {token, _status} = Map.fetch!(calls.calls, id)
    %{calls | calls: Map.put(calls.calls, id, {token, status})}
  end

  defp remove(calls, id) do
    {{token, _status}, rest} = Map.pop!(calls.calls, id)
    %{calls | calls: rest, tokens: Map.delete(calls.tokens, token)}
  end

  defp notify_cancel(calls, id) do
    {token, _status} = Map.fetch!(calls.calls, id)

    %{
      calls
      | calls: Map.put(calls.calls, id, {token, :cancelling}),
        tokens: Map.delete(calls.tokens, token),
        queue: :queue.in({:cancel, id}, calls.queue)
    }
  end

  defp dispatch(%{busy: nil} = calls, vm) do
    case :queue.out(calls.queue) do
      {{:value, {:call, id}}, queue} ->
        {token, {:queued, name, args}} = Map.fetch!(calls.calls, id)
        send(calls.handler, {:"$kettlecorn_host_call", {vm, id, token}, name, args})
        %{put(calls, id, :running) | queue: queue, busy: {:call, id}}

      {{:value, {:cancel, id}}, queue} ->
        {token, :cancelling} = Map.fetch!(calls.calls, id)
        send(calls.handler, {:"$kettlecorn_host_call_cancel", {vm, id, token}})
        %{calls | queue: queue, busy: {:cancel, id}}

      {:empty, _queue} ->
        calls
    end
  end

  defp dispatch(calls, _vm), do: calls

  # Linked so it stops with the VM, and monitored so the VM learns when it
  # exits without a result.
  defp start_task(vm, id, token, name, function, args) do
    {pid, monitor} =
      Process.spawn(
        fn ->
          reply = prepare(token, run(name, function, args), name)
          GenServer.cast(vm, {:host_calls, {:result, id, reply}})
        end,
        [:link, :monitor]
      )

    {:task, pid, monitor}
  end

  defp stop_task(pid, monitor) do
    Process.demonitor(monitor, [:flush])
    Process.unlink(pid)
    Process.exit(pid, :kill)
  end

  defp run(name, function, args) do
    function.(args)
  catch
    kind, reason ->
      Logger.error(
        "kettlecorn: host function #{inspect(name)} failed: " <>
          Exception.format(kind, reason, __STACKTRACE__)
      )

      {:error, "host function failed"}
  end
end
