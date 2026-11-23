defmodule Kettlecorn.HostHandler.Server do
  @moduledoc false
  use GenServer

  alias Kettlecorn.VM.HostCalls

  def start_link(module, arg), do: GenServer.start_link(__MODULE__, {module, arg})

  @impl true
  def init({module, arg}) do
    Code.ensure_loaded(module)

    case module.init(arg) do
      {:ok, state} -> {:ok, {module, state}}
      {:stop, reason} -> {:stop, reason}
    end
  end

  # Acknowledges each call and cancel notice when its callback returns, so
  # the VM can send the next one.
  @impl true
  def handle_info({:"$kettlecorn_host_call", {vm, id, token} = from, name, args}, {module, state}) do
    {reply, state} =
      case module.handle_host_call(name, args, from, state) do
        {:reply, result, state} -> {HostCalls.prepare(token, result, name), state}
        {:noreply, state} -> {:noreply, state}
      end

    GenServer.cast(vm, {:host_calls, {:ack, id, reply}})
    {:noreply, {module, state}}
  end

  def handle_info({:"$kettlecorn_host_call_cancel", {vm, _id, _token} = from}, {module, state}) do
    result = optional(module, :handle_cancel, [from, state], state)
    GenServer.cast(vm, {:host_calls, :cancel_ack})
    result
  end

  def handle_info(message, {module, state}),
    do: optional(module, :handle_info, [message, state], state)

  defp optional(module, callback, args, state) do
    if function_exported?(module, callback, length(args)) do
      {:noreply, new_state} = apply(module, callback, args)
      {:noreply, {module, new_state}}
    else
      {:noreply, {module, state}}
    end
  end
end
