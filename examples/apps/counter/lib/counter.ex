defmodule Counter do
  @moduledoc "A supervised counter initialized from cook-time configuration."
  use GenServer

  def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: :counter)

  def increment, do: GenServer.call(:counter, :increment)
  def value, do: GenServer.call(:counter, :value)

  @impl true
  def init([]), do: {:ok, Application.fetch_env!(:counter, :initial_value)}

  @impl true
  def handle_call(:increment, _from, value), do: {:reply, value + 1, value + 1}
  def handle_call(:value, _from, value), do: {:reply, value, value}
end

defmodule Counter.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    Supervisor.start_link([Counter], strategy: :one_for_one, name: Counter.Supervisor)
  end
end
