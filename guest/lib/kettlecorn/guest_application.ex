defmodule Kettlecorn.GuestApplication do
  @moduledoc false
  use Application

  alias Kettlecorn.Boot
  alias Kettlecorn.HTTP.ReqAdapter

  @impl true
  def start(_type, _args) do
    # Try the WASI DNS NIF before guest host files; DNS requires the network grant.
    :inet_db.set_lookup([:native, :file])
    install_req_adapter()
    children = [Kettlecorn.HostCalls, Kettlecorn.Proxy, Kettlecorn.Evaluator]
    Supervisor.start_link(children, strategy: :one_for_one, name: Kettlecorn.GuestSupervisor)
  end

  defp install_req_adapter do
    if Code.ensure_loaded?(ReqAdapter) do
      cond do
        Kettlecorn.HTTP.available?() -> put_default_adapter(ReqAdapter)
        Boot.network_granted?() -> :ok
        true -> put_default_adapter(ReqAdapter.Disabled)
      end
    end
  end

  defp put_default_adapter(adapter) do
    opts = Application.get_env(:req, :default_options, [])
    Application.put_env(:req, :default_options, Keyword.put_new(opts, :adapter, adapter))
  end
end
