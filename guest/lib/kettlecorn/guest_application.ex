defmodule Kettlecorn.GuestApplication do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    # Try the WASI DNS NIF before guest host files; DNS requires the network grant.
    :inet_db.set_lookup([:native, :file])
    install_req_adapter()
    children = [Kettlecorn.Proxy, Kettlecorn.Evaluator]
    Supervisor.start_link(children, strategy: :one_for_one, name: Kettlecorn.GuestSupervisor)
  end

  defp install_req_adapter do
    if Code.ensure_loaded?(Kettlecorn.HTTP.ReqAdapter) and Kettlecorn.HTTP.available?() do
      opts = Application.get_env(:req, :default_options, [])
      opts = Keyword.put_new(opts, :adapter, Kettlecorn.HTTP.ReqAdapter)
      Application.put_env(:req, :default_options, opts)
    end
  end
end
