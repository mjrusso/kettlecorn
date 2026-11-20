defmodule MonitorPlugin do
  use GenServer

  def start do
    {:ok, _} = GenServer.start(__MODULE__, %{}, name: __MODULE__)
    :ok
  end

  def handle_event(%{"type" => "sample", "device" => device, "temperature" => temperature}) do
    GenServer.call(__MODULE__, {:sample, device, temperature})
  end

  def handle_event(%{"type" => "crash"}), do: :ok

  @impl true
  def init(readings), do: {:ok, readings}

  @impl true
  def handle_call({:sample, device, temperature}, _from, readings) do
    case readings do
      %{^device => previous} when temperature - previous >= 15 ->
        {:ok, :ok} =
          Kettlecorn.Host.call("emit_alert", %{
            "device" => device,
            "kind" => "rapid_rise",
            "temperature" => temperature
          })

      _ ->
        :ok
    end

    {:reply, :ok, Map.put(readings, device, temperature)}
  end
end
