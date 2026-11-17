# Hex packages shipped in the guest. The flake fetches them with
# fetchMixDeps from mix.lock (see nix/guest-deps.nix); after changing the
# list, run `just update-guest-deps` to refresh mix.lock and the hash.
defmodule KettlecornGuestDeps.MixProject do
  use Mix.Project

  def project do
    [app: :kettlecorn_guest_deps, version: "0.1.0", deps: deps()]
  end

  defp deps do
    [
      {:req, "~> 0.7"},
      # telemetry's rebar.config pulls in a rebar3 plugin from Hex, which the
      # Nix sandbox can't download; it also ships a mix.exs.
      {:telemetry, "~> 1.0", manager: :mix, override: true}
    ]
  end
end
