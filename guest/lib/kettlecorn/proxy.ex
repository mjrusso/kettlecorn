defmodule Kettlecorn.Proxy do
  @moduledoc false
  use GenServer

  @name :kettlecorn_proxy

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: @name)

  @impl true
  def init(nil), do: {:ok, nil}

  @impl true
  def handle_info(
        {:wasm,
         {id,
          %{
            "kind" => "call",
            "target" => target,
            "request" => request,
            "proxy_timeout_ms" => timeout
          }}},
        state
      ) do
    pid = whereis(target)
    spawn(fn -> reply(id, call(pid, request, timeout)) end)
    {:noreply, state}
  end

  def handle_info(
        {:wasm, {_id, %{"kind" => "cast", "target" => target, "request" => request}}},
        state
      ) do
    if pid = whereis(target), do: GenServer.cast(pid, request)
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp call(nil, _request, _timeout), do: {:error, :noproc}

  defp call(pid, request, timeout) do
    {:ok, GenServer.call(pid, request, timeout)}
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, {:noproc, _} -> {:error, :noproc}
    :exit, {reason, _} -> {:error, {:exit, inspect(reason)}}
  end

  defp reply(id, result) do
    event = %{event: :proxy_reply, id: id, result: result}

    case Kettlecorn.Event.send(event) do
      :ok ->
        :ok

      {:error, :frame_too_large} ->
        Kettlecorn.Event.send(%{event | result: {:error, :frame_too_large}})
    end
  end

  defp whereis(name) when is_binary(name) do
    GenServer.whereis(String.to_existing_atom(name))
  rescue
    ArgumentError -> nil
  end

  defp whereis(_), do: nil
end
