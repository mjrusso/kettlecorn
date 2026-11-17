# Crypto (always available), HTTP and sockets (only when granted).
#   kettlecorn-run examples/06_network.exs http://127.0.0.1:8000/
#   kettlecorn-run --http --network examples/06_network.exs http://127.0.0.1:8000/
[url] = System.argv()
uri = URI.parse(url)

IO.puts("sha256(\"hello\") = " <> Base.encode16(:crypto.hash(:sha256, "hello"), case: :lower))
IO.puts("16 random bytes: " <> Base.encode64(:crypto.strong_rand_bytes(16)))

IO.puts("\nHTTP via wasi:http (Kettlecorn.HTTP), available: #{Kettlecorn.HTTP.available?()}")

case Kettlecorn.HTTP.request(:get, url) do
  {:ok, %{status: status, body: body}} -> IO.puts("  #{status}, #{byte_size(body)} bytes")
  {:error, reason} -> IO.puts("  error: #{inspect(reason)}")
end

IO.puts("\nTCP via wasi:sockets (:gen_tcp)")

case :gen_tcp.connect(String.to_charlist(uri.host), uri.port, [:binary, active: false], 5_000) do
  {:ok, socket} ->
    :ok = :gen_tcp.send(socket, "HEAD #{uri.path || "/"} HTTP/1.0\r\nhost: #{uri.host}\r\n\r\n")
    {:ok, reply} = :gen_tcp.recv(socket, 0, 5_000)
    IO.puts("  " <> (reply |> String.split("\r\n") |> hd()))

  {:error, reason} ->
    IO.puts("  error: #{inspect(reason)}")
end
