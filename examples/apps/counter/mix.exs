defmodule Counter.MixProject do
  use Mix.Project

  def project do
    [
      app: :counter,
      version: "0.1.0",
      elixir: "~> 1.20",
      deps: [{:kettlecorn, path: "../../../host", runtime: false}]
    ]
  end

  def application do
    [mod: {Counter.Application, []}]
  end
end
