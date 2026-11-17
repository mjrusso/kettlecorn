# Spawn processes dynamically and pass messages between them.

defmodule Squarer do
  def loop do
    receive do
      {:square, from, n} ->
        send(from, {:squared, self(), n, n * n})
        loop()

      :stop ->
        :ok
    end
  end
end

parent = self()

# 1. Fan out: one process per number, collect the replies.
workers = for _ <- 1..5, do: spawn(&Squarer.loop/0)

workers
|> Enum.with_index(1)
|> Enum.each(fn {pid, n} -> send(pid, {:square, parent, n}) end)

results =
  for _ <- workers do
    receive do
      {:squared, pid, n, sq} -> {n, sq, pid}
    after
      1_000 -> raise "worker didn't answer"
    end
  end

for {n, sq, pid} <- Enum.sort(results) do
  IO.puts("#{inspect(pid)} squared #{n} -> #{sq}")
end

Enum.each(workers, &send(&1, :stop))

# 2. A ring: pass a token around 1000 processes, then stop the workers.
forward = fn next ->
  loop = fn loop ->
    receive do
      {:token, 0} ->
        send(next, {:token, 0})

      {:token, hops} ->
        send(next, {:token, hops - 1})
        loop.(loop)
    end
  end

  loop.(loop)
end

me = self()
first = Enum.reduce(1..999, me, fn _, next -> spawn(fn -> forward.(next) end) end)
send(first, {:token, 1_000 * 10})

g = fn g ->
  receive do
    {:token, 0} ->
      :done

    {:token, hops} ->
      send(first, {:token, hops - 1})
      g.(g)
  end
end

:done = g.(g)

IO.puts("Passed a token around a ring of 1000 processes")

# 3. Monitors: notice when a process dies.
{pid, ref} = spawn_monitor(fn -> exit(:boom) end)

receive do
  {:DOWN, ^ref, :process, ^pid, reason} ->
    IO.puts("Monitored process exited with #{inspect(reason)}")
end
