defmodule Kettlecorn.VM.Termination do
  @moduledoc false

  alias Kettlecorn.Sandbox.Instance

  @type outcome :: {:exited, integer()} | :cancelled | :timeout | :out_of_fuel | :failed
  @type t :: %{outcome: outcome() | nil, stats: Kettlecorn.stats() | nil}

  @spec read(Instance.t()) :: t()
  def read(instance) do
    case fetch(instance) do
      {:ok, termination} -> termination
      :missing -> %{outcome: nil, stats: nil}
    end
  end

  @doc """
  Waits until `deadline` (monotonic milliseconds) for the launcher to
  publish its record, which also confirms its cleanup, then reads it.
  """
  @spec await(Instance.t(), integer()) :: {:ok, t()} | :timeout
  def await(instance, deadline) do
    case fetch(instance) do
      {:ok, termination} ->
        {:ok, termination}

      :missing ->
        if System.monotonic_time(:millisecond) >= deadline do
          :timeout
        else
          Process.sleep(10)
          await(instance, deadline)
        end
    end
  end

  # The launcher publishes the record with a rename, so a file that exists is complete.
  defp fetch(instance) do
    case File.read(Instance.stderr_file(instance) <> ".stopped") do
      {:ok, json} -> {:ok, parse(JSON.decode(json), instance.sandbox.max_fuel != :infinity)}
      {:error, _reason} -> :missing
    end
  end

  defp parse({:ok, %{} = record}, metered),
    do: %{outcome: outcome(record), stats: stats(record, metered)}

  defp parse(_invalid, _metered), do: %{outcome: nil, stats: nil}

  defp outcome(%{"outcome" => "exited", "code" => code}) when is_integer(code),
    do: {:exited, code}

  defp outcome(%{"outcome" => "cancelled"}), do: :cancelled
  defp outcome(%{"outcome" => "timeout"}), do: :timeout
  defp outcome(%{"outcome" => "out_of_fuel"}), do: :out_of_fuel
  defp outcome(%{"outcome" => "failed"}), do: :failed
  defp outcome(_record), do: nil

  defp stats(%{"memory" => memory} = record, metered) when is_integer(memory) and memory >= 0 do
    case {record, metered} do
      {%{"fuel_consumed" => fuel}, true} when is_integer(fuel) and fuel >= 0 ->
        %{fuel_consumed: fuel, memory: memory, rss: nil}

      {_record, false} ->
        %{fuel_consumed: nil, memory: memory, rss: nil}

      _missing_fuel ->
        nil
    end
  end

  defp stats(_record, _metered), do: nil
end
