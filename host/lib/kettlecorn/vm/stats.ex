defmodule Kettlecorn.VM.Stats do
  @moduledoc false
  # Keep reads on the stats caller so retries cannot block the VM mailbox.

  import Bitwise

  alias Kettlecorn.Sandbox.Instance

  @busy_timeout 1_000
  @mask 0xFFFF_FFFF_FFFF_FFFF

  @spec read(Instance.t(), non_neg_integer() | nil) ::
          {:ok, Kettlecorn.stats()} | {:error, term()}
  def read(instance, os_pid) do
    with {:ok, {fuel, memory}} <- usage(Instance.stats_file(instance)) do
      {:ok,
       %{
         fuel_consumed: if(instance.sandbox.max_fuel == :infinity, do: nil, else: fuel),
         memory: memory,
         rss: rss(os_pid)
       }}
    end
  end

  @doc false
  @spec decode(binary()) :: {:ok, {non_neg_integer(), non_neg_integer()}} | :error
  def decode(<<fuel::little-64, memory::little-64, checksum::little-64>>) do
    if checksum == mix(bxor(fuel, mix(memory))), do: {:ok, {fuel, memory}}, else: :error
  end

  def decode(_record), do: :error

  defp usage(path) do
    deadline = System.monotonic_time(:millisecond) + @busy_timeout

    with {:ok, result} <- File.open(path, [:read, :binary, :raw], &consistent(&1, deadline)),
         do: result
  end

  defp consistent(file, deadline) do
    with {:ok, record} <- :file.pread(file, 0, 24),
         {:ok, usage} <- decode(record) do
      {:ok, usage}
    else
      {:error, reason} ->
        {:error, reason}

      _ ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(1)
          consistent(file, deadline)
        else
          {:error, :stats_busy}
        end
    end
  end

  # The SplitMix64 finalizer (`PROTOCOL.md`).
  defp mix(z) do
    z = bxor(z, z >>> 30) * 0xBF58476D1CE4E5B9 &&& @mask
    z = bxor(z, z >>> 27) * 0x94D049BB133111EB &&& @mask
    bxor(z, z >>> 31)
  end

  defp rss(nil), do: nil

  defp rss(os_pid) do
    with {:ok, status} <- File.read("/proc/#{os_pid}/status"),
         [_, kilobytes] <- Regex.run(~r/^VmRSS:\s+(\d+) kB$/m, status) do
      String.to_integer(kilobytes) * 1024
    else
      _ -> nil
    end
  end
end
