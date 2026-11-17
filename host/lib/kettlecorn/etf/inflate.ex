defmodule Kettlecorn.ETF.Inflate do
  @moduledoc false
  # Reach treats zlib as I/O; keep decompression outside the pure ETF parser.

  @doc """
  Inflates `compressed` to exactly `size` bytes, or returns `:error`.
  Reads bounded chunks and rejects output as soon as the accumulated size
  exceeds `size`.
  """
  @spec inflate(binary(), non_neg_integer()) :: {:ok, binary()} | :error
  def inflate(compressed, size) do
    z = :zlib.open()

    try do
      :ok = :zlib.inflateInit(z)
      collect(z, :zlib.safeInflate(z, compressed), size, [], 0)
    catch
      _, _ -> :error
    after
      :zlib.close(z)
    end
  end

  defp collect(z, {status, chunk}, size, acc, total) do
    total = total + IO.iodata_length(chunk)

    cond do
      total > size -> :error
      status == :continue -> collect(z, :zlib.safeInflate(z, []), size, [acc | chunk], total)
      total == size -> {:ok, IO.iodata_to_binary([acc | chunk])}
      true -> :error
    end
  end

  defp collect(_z, _need_dictionary, _size, _acc, _total), do: :error
end
