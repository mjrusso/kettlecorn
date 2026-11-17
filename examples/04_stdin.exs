# Count words from standard input in concurrent tasks.
#   echo "the quick brown fox jumps over the lazy dog the end" | kettlecorn-run examples/04_stdin.exs

counts =
  IO.stream(:stdio, :line)
  |> Task.async_stream(fn line ->
    line |> String.split() |> Enum.frequencies()
  end)
  |> Enum.reduce(%{}, fn {:ok, freq}, acc -> Map.merge(acc, freq, fn _, a, b -> a + b end) end)

counts
|> Enum.sort_by(fn {word, n} -> {-n, word} end)
|> Enum.take(5)
|> Enum.each(fn {word, n} -> IO.puts("#{String.pad_trailing(word, 10)} #{n}") end)
