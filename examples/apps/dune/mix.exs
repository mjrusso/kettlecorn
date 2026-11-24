defmodule DuneExample.MixProject do
  use Mix.Project

  def project do
    [
      app: :dune_example,
      version: "0.1.0",
      elixir: "~> 1.20",
      deps: [{:kettlecorn, path: "../../../host", runtime: false}, {:dune, "0.3.18"}]
    ]
  end

  def application do
    [mod: {DuneExample.Application, []}, extra_applications: [:logger]]
  end
end
