defmodule LuaExample do
  @moduledoc """
  A guest GenServer that retains Lua state between calls.

  The bundled receipt script takes its issue time and code from the request.
  """
  use GenServer

  @unavailable [
    [:os, :clock],
    [:os, :date],
    [:os, :time],
    [:os, :time_ms],
    [:os, :time_us],
    [:math, :random],
    [:math, :randomseed]
  ]

  def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: :lua_example)

  def transform(event), do: GenServer.call(:lua_example, {:transform, event})

  @doc "Issues a receipt with a Unix timestamp in seconds and a caller-supplied integer code."
  def receipt(event, issued_at, code),
    do: GenServer.call(:lua_example, {:receipt, event, issued_at, code})

  @impl true
  def init([]) do
    script = :lua_example |> :code.priv_dir() |> Path.join("transform.lua") |> File.read!()
    lua = Lua.new(max_instructions: 100_000, max_call_depth: 100, max_string_bytes: 1_000_000)
    lua = Enum.reduce(@unavailable, lua, &Lua.sandbox(&2, &1))
    {[], lua} = Lua.eval!(lua, script)
    {:ok, lua}
  end

  @impl true
  def handle_call({:transform, event}, _from, lua), do: run(lua, :transform, [event])

  def handle_call({:receipt, event, issued_at, code}, _from, lua)
      when is_integer(issued_at) and is_integer(code),
      do: run(lua, :receipt, [event, issued_at, code])

  def handle_call({:receipt, _event, _issued_at, _code}, _from, lua),
    do: {:reply, {:error, "issued_at and code must be integers"}, lua}

  defp run(lua, function, args) do
    {args, lua} = Enum.map_reduce(args, lua, &Lua.encode!(&2, &1))

    case Lua.call_function(lua, [function], args) do
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
