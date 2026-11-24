defmodule Kettlecorn.HostCalls do
  @moduledoc false
  # The caller sends timeout notices before it can issue its next call.
  # This process handles caller exits outside evaluation budgets.
  use GenServer

  @compile {:no_warn_undefined, :wasm}

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: :kettlecorn_host_calls)

  # Preload can run on_load callbacks before the router starts.
  def call(name, args, timeout) do
    case Process.whereis(:kettlecorn_host_calls) do
      nil -> call_directly(name, args, timeout)
      router -> call_through(router, name, args, timeout)
    end
  end

  defp call_directly(name, args, timeout) do
    token = make_ref()
    reply_to = :erlang.term_to_binary({self(), token})

    case request(name, args, reply_to) do
      :ok ->
        receive do
          {:wasm, {^token, result}} ->
            result
        after
          timeout ->
            cancel(reply_to)
            {:error, :timeout}
        end

      error ->
        error
    end
  end

  defp call_through(router, name, args, timeout) do
    call = :erlang.alias()
    monitor = Process.monitor(router)

    try do
      reply_to = :erlang.term_to_binary({router, call})
      send(router, {:pending, call, self(), reply_to})

      case request(name, args, reply_to) do
        :ok ->
          receive do
            {:wasm, {^call, result}} ->
              result

            {:DOWN, ^monitor, :process, _router, _reason} ->
              cancel(reply_to)
              {:error, :interrupted}
          after
            timeout ->
              :erlang.unalias(call)

              # Unaliasing blocks future deliveries. Drain a reply already in the mailbox.
              receive do
                {:wasm, {^call, _result}} -> :ok
              after
                0 -> :ok
              end

              cancel(reply_to)
              {:error, :timeout}
          end

        {:error, :frame_too_large} = error ->
          error
      end
    after
      Process.demonitor(monitor, [:flush])
      :erlang.unalias(call)
      send(router, {:forget, call})
    end
  end

  defp request(name, args, reply_to),
    do: :wasm.send_envelope(%{type: :host_call, name: name, args: args, reply_to: reply_to})

  defp cancel(reply_to),
    do: :wasm.send_envelope(%{type: :host_call_cancel, reply_to: reply_to})

  @impl true
  def init(nil), do: {:ok, %{}}

  # Pending calls: alias => {caller monitor, reply_to}. Each monitor is
  # tagged with its call's alias.
  @impl true
  def handle_info({:pending, call, pid, reply_to}, calls) do
    monitor = :erlang.monitor(:process, pid, tag: {:caller, call})
    {:noreply, Map.put(calls, call, {monitor, reply_to})}
  end

  def handle_info({:wasm, {call, result}}, calls) do
    {reply_to, calls} = forget(calls, call)
    if reply_to, do: send(call, {:wasm, {call, result}})
    {:noreply, calls}
  end

  def handle_info({:forget, call}, calls), do: {:noreply, calls |> forget(call) |> elem(1)}

  def handle_info({{:caller, call}, _monitor, :process, _pid, _reason}, calls) do
    {reply_to, calls} = forget(calls, call)
    if reply_to, do: :wasm.send_envelope(%{type: :host_call_cancel, reply_to: reply_to})
    {:noreply, calls}
  end

  def handle_info(_message, calls), do: {:noreply, calls}

  defp forget(calls, call) do
    case Map.pop(calls, call) do
      {{monitor, reply_to}, calls} ->
        :erlang.demonitor(monitor, [:flush])
        {reply_to, calls}

      {nil, calls} ->
        {nil, calls}
    end
  end
end
