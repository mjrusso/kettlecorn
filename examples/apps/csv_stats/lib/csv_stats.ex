NimbleCSV.define(CsvStats.Parser, separator: ",", escape: "\"")

defmodule CsvStats do
  @moduledoc """
  Summarizes sales by region using NimbleCSV and a data file in `priv/`.
  """

  @doc "Revenue per region, highest first: [{region, revenue}]."
  def by_region(path \\ default_path()) do
    path
    |> File.read!()
    |> CsvStats.Parser.parse_string()
    |> Enum.map(fn [region, _product, units, price] ->
      {region, String.to_integer(units) * String.to_float(price)}
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.map(fn {region, amounts} -> {region, Float.round(Enum.sum(amounts), 2)} end)
    |> Enum.sort_by(&elem(&1, 1), :desc)
  end

  @doc "Prints the report."
  def report do
    currency = Application.fetch_env!(:csv_stats, :currency)
    IO.puts("Revenue by region (#{currency}):")

    for {region, revenue} <- by_region() do
      IO.puts("  #{String.pad_trailing(region, 6)} #{:erlang.float_to_binary(revenue, decimals: 2)}")
    end

    :ok
  end

  defp default_path, do: Path.join(:code.priv_dir(:csv_stats), "sales.csv")
end
