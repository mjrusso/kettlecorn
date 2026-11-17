defmodule LuaExample do
  @moduledoc "A guest GenServer that retains Lua state between order transformations."
  use GenServer

  def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: :lua_example)

  def transform(event), do: GenServer.call(:lua_example, {:transform, event})

  @impl true
  def init([]) do
    script = :lua_example |> :code.priv_dir() |> Path.join("transform.lua") |> File.read!()
    lua = Lua.new(max_instructions: 100_000, max_call_depth: 100, max_string_bytes: 1_000_000)
    {[], lua} = Lua.eval!(lua, script)
    {:ok, lua}
  end

  @impl true
  def handle_call({:transform, event}, _from, lua) do
    {event, lua} = Lua.encode!(lua, event)

    case Lua.call_function(lua, [:transform], [event]) do
      {:ok, result, lua} -> {:reply, {:ok, result}, lua}
      {:error, error, lua} -> {:reply, {:error, Exception.message(error)}, lua}
    end
  end
end

defmodule LuaExample.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    Supervisor.start_link([LuaExample], strategy: :one_for_one, name: LuaExample.Supervisor)
  end
end
