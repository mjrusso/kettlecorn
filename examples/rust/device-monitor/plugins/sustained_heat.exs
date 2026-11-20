defmodule MonitorPlugin do
  use GenServer

  def start do
    {:ok, supervisor} =
      Supervisor.start_link(
        [
          {Registry, keys: :unique, name: MonitorRegistry},
          {DynamicSupervisor, strategy: :one_for_one, name: DeviceSupervisor}
        ],
        strategy: :one_for_one
      )

    # The evaluator process exits after startup.
    Process.unlink(supervisor)
    :ok
  end

  def handle_event(%{"type" => "sample", "device" => device, "temperature" => temperature}) do
    pid =
      case GenServer.whereis(via(device)) do
        nil ->
          {:ok, pid} = DynamicSupervisor.start_child(DeviceSupervisor, {__MODULE__, device})
          pid

        pid ->
          pid
      end

    GenServer.call(pid, {:sample, temperature})
  end

  def handle_event(%{"type" => "crash", "device" => device}) do
    pid = GenServer.whereis(via(device)) || raise "device #{device} has no worker"
    restart = {:restart, device}
    {:ok, _} = Registry.register(MonitorRegistry, restart, nil)
    Process.exit(pid, :kill)

    receive do
      {:restarted, ^device} ->
        Registry.unregister(MonitorRegistry, restart)
        IO.puts("sustained_heat: restarted worker for #{device}")
        emit(device, "worker_restarted")
    after
      2_000 -> raise "device #{device} did not restart"
    end
  end

  def start_link(device), do: GenServer.start_link(__MODULE__, device, name: via(device))

  @impl true
  def init(device) do
    case Registry.lookup(MonitorRegistry, {:restart, device}) do
      [{waiter, nil}] -> send(waiter, {:restarted, device})
      [] -> :ok
    end

    {:ok, {device, 0}}
  end

  @impl true
  def handle_call({:sample, temperature}, _from, {device, streak}) do
    next = if temperature >= 80, do: min(streak + 1, 3), else: 0

    case {streak, next} do
      {2, 3} -> emit(device, "high", %{"temperature" => temperature})
      {3, 0} -> emit(device, "recovered", %{"temperature" => temperature})
      _ -> :ok
    end

    {:reply, :ok, {device, next}}
  end

  defp emit(device, kind, fields \\ %{}) do
    {:ok, :ok} =
      Kettlecorn.Host.call("emit_alert", Map.merge(fields, %{"device" => device, "kind" => kind}))

    :ok
  end

  defp via(device), do: {:via, Registry, {MonitorRegistry, device}}
end
