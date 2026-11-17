# A program that never ends: use the sandbox's limits to stop it.
#   kettlecorn-run --fuel 5000000000 examples/05_runaway.exs
#   kettlecorn-run --timeout 2s examples/05_runaway.exs
#   kettlecorn-run --max-memory 67108864 examples/05_runaway.exs memory
case System.argv() do
  ["memory"] ->
    IO.puts("allocating forever...")
    Stream.iterate([], &[:binary.copy("x", 1_000_000) | &1]) |> Stream.run()

  _ ->
    IO.puts("spinning forever...")
    Stream.repeatedly(fn -> :erlang.phash2(:rand.uniform()) end) |> Stream.run()
end
