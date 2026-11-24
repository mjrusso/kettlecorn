defmodule Kettlecorn.MixProject do
  use Mix.Project

  # The version is in its own file so that releases don't change mix.exs
  # (nix/host-tests.nix's fetchMixDeps hash covers it). The flake reads it too:
  # it's the runtime's version.
  @version "VERSION" |> File.read!() |> String.trim()
  @source_url "https://github.com/mjrusso/kettlecorn"
  @notebooks ~w(notebooks/getting-started.livemd notebooks/working-with-guests.livemd notebooks/use-cases.livemd notebooks/network.livemd notebooks/guest-data.livemd notebooks/internals.livemd)
  @user_guides ~w(guides/sandbox.md guides/running-applications.md guides/guest-api.md)
  @contributor_guides ~w(guides/architecture.md guides/development.md guides/performance.md)
  @guides @user_guides ++ @contributor_guides

  def project do
    [
      app: :kettlecorn,
      version: @version,
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      dialyzer: [plt_add_apps: [:mix, :ex_unit]],
      description: "Run untrusted Elixir and Erlang in WebAssembly VMs",
      package: package(),
      docs: docs(),
      source_url: @source_url
    ]
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url},
      files:
        ~w(lib priv mix.exs VERSION PROTOCOL_VERSION README.md CHANGELOG.md LICENSE .formatter.exs) ++
          @notebooks ++ @guides
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md"] ++ @notebooks ++ @guides ++ ["CHANGELOG.md"],
      groups_for_extras: [
        Notebooks: @notebooks,
        Guides: @user_guides,
        Contributing: @contributor_guides,
        Reference: ["CHANGELOG.md"]
      ],
      source_ref: "v#{@version}",
      source_url_pattern: "#{@source_url}/blob/v#{@version}/host/%{path}#L%{line}"
    ]
  end

  # :inets/:ssl/:public_key/:crypto: Kettlecorn.Install downloads
  # and checks the runtime (the tests' TLS server uses them too).
  def application do
    [extra_applications: [:logger, :crypto, :public_key, :ssl, :inets]]
  end

  # nix/host-tests.nix fetches only test dependencies; check tools stay in dev.
  defp deps do
    [
      {:nimble_options, "~> 1.2"},
      {:stream_data, "~> 1.2", only: :test},
      {:benchee, "~> 1.3", only: :bench},
      {:credo, "~> 1.7.19", only: :dev, runtime: false},
      {:ex_slop, "~> 0.4.5", only: :dev, runtime: false},
      {:ex_dna, "~> 1.5.4", only: :dev, runtime: false},
      {:reach, "~> 2.8.4", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4.8", only: :dev, runtime: false},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false}
    ]
  end
end
