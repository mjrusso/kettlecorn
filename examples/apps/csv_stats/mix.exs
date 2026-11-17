defmodule CsvStats.MixProject do
  use Mix.Project

  def project do
    [
      app: :csv_stats,
      version: "0.1.0",
      elixir: "~> 1.20",
      deps: [{:kettlecorn, path: "../../../host", runtime: false}, {:nimble_csv, "~> 1.2"}]
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end
end
