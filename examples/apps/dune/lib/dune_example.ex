defmodule DuneExample do
  @moduledoc """
  A guest GenServer that evaluates Elixir code with Dune and
  `DuneExample.Allowlist`, keeping bindings and modules between evaluations.
  """
  use GenServer

  @opts [allowlist: DuneExample.Allowlist, timeout: 5_000, inspect_sort_maps: true]

  def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: :dune_example)

  @doc """
  Returns `{:ok, inspected_value, stdout}` or `{:error, type, message}`,
  where `type` is Dune's failure type, such as `:restricted`.
  """
  def eval(code), do: GenServer.call(:dune_example, {:eval, code}, 10_000)

  @impl true
  def init([]), do: {:ok, Dune.Session.new()}

  @impl true
  def handle_call({:eval, code}, _from, session) do
    session = Dune.Session.eval_string(session, code, @opts)

    reply =
      case session.last_result do
        %Dune.Success{inspected: value, stdio: stdout} -> {:ok, value, stdout}
        %Dune.Failure{type: type, message: message} -> {:error, type, message}
      end

    {:reply, reply, session}
  end
end

defmodule DuneExample.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    Supervisor.start_link([DuneExample], strategy: :one_for_one, name: DuneExample.Supervisor)
  end
end
