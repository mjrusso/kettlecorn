defmodule Kettlecorn.MixProject do
  use Mix.Project

  # The version is in its own file so that releases don't change mix.exs
  # (nix/host-tests.nix's fetchMixDeps hash covers it). The flake reads it too:
  # it's the runtime's version.
  @version "VERSION" |> File.read!() |> String.trim()
  @source_url "https://github.com/mjrusso/kettlecorn"

  def project do
    [
      app: :kettlecorn,
      version: @version,
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      dialyzer: [plt_add_apps: [:mix, :ex_unit]],
      description: "Run untrusted Elixir and Erlang in WebAssembly VMs",
      source_url: @source_url
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
      {:stream_data, "~> 1.2", only: :test},
      {:credo, "~> 1.7.19", only: :dev, runtime: false},
      {:ex_slop, "~> 0.4.5", only: :dev, runtime: false},
      {:ex_dna, "~> 1.5.4", only: :dev, runtime: false},
      {:reach, "~> 2.8.4", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4.8", only: :dev, runtime: false},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false}
    ]
  end
end
