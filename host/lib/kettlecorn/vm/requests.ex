defmodule Kettlecorn.VM.Requests do
  @moduledoc false

  defstruct limit: 1_024, next_id: 1, entries: %{}, monitors: %{}

  def new(limit), do: %__MODULE__{limit: limit}

  def admit(requests, kind, {caller, _tag} = from, timeout) do
    if map_size(requests.entries) >= requests.limit do
      :full
    else
      {id, requests} = next_id(requests)
      monitor = Process.monitor(caller)

      timer =
        if timeout != :infinity,
          do: Process.send_after(self(), {:deadline, id, monitor}, timeout)

      {:ok, id,
       %{
         requests
         | entries: Map.put(requests.entries, id, {kind, from, monitor, timer}),
           monitors: Map.put(requests.monitors, monitor, id)
       }}
    end
  end

  def next_id(requests) do
    id = requests.next_id
    requests = %{requests | next_id: rem(id + 1, 0x1_0000_0000)}

    if Map.has_key?(requests.entries, id),
      do: next_id(requests),
      else: {id, requests}
  end

  def kind(requests, id) do
    case Map.get(requests.entries, id) do
      {kind, _from, _monitor, _timer} -> kind
      nil -> nil
    end
  end

  def reply(requests, id, result) do
    case Map.get(requests.entries, id) do
      {_kind, from, _monitor, _timer} ->
        requests = remove(requests, id)
        GenServer.reply(from, result)
        requests

      nil ->
        requests
    end
  end

  def expire(requests, id, monitor) do
    if Map.get(requests.monitors, monitor) == id,
      do: reply(requests, id, {:error, :timeout}),
      else: requests
  end

  def caller_down(requests, monitor) do
    case Map.fetch(requests.monitors, monitor) do
      {:ok, id} -> remove(requests, id)
      :error -> requests
    end
  end

  def fail_all(requests, reason) do
    Enum.reduce(Map.keys(requests.entries), requests, &reply(&2, &1, {:error, reason}))
  end

  defp remove(requests, id) do
    {{_kind, _from, monitor, timer}, entries} = Map.pop!(requests.entries, id)
    if timer, do: Process.cancel_timer(timer)
    Process.demonitor(monitor, [:flush])
    %{requests | entries: entries, monitors: Map.delete(requests.monitors, monitor)}
  end
end
