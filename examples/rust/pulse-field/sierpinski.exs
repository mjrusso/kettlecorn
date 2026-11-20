defmodule Bot do
  def init(%{"center" => {cx, _}}) do
    for y <- 0..15 do
      board_y = 4 + y

      pid =
        spawn_link(fn ->
          cells =
            for x <- 0..y, Bitwise.band(x, y) == x do
              {cx + 2 * x - y, board_y}
            end

          paint_row(cells, 2 * y)
        end)

      {board_y, pid}
    end
  end

  def frame(%{"tick" => tick, "pulses" => pulses}, workers) do
    arrivals =
      Enum.group_by(pulses, fn {_, {_, y}, _} -> y end, fn {_, cell, _} -> cell end)

    requests =
      for {y, pid} <- workers do
        ref = make_ref()
        send(pid, {:paint, self(), ref, tick, Map.get(arrivals, y, [])})
        ref
      end

    marks =
      Enum.flat_map(requests, fn ref ->
        receive do
          {^ref, marks} -> marks
        end
      end)

    {%{"marks" => marks}, workers}
  end

  defp paint_row(cells, reveal_at, lit_until \\ %{}) do
    receive do
      {:paint, caller, ref, tick, _arrivals} when tick < reveal_at ->
        send(caller, {ref, []})
        paint_row(cells, reveal_at, lit_until)

      {:paint, caller, ref, tick, arrivals} ->
        {marks, lit_until} =
          Enum.map_reduce(cells, lit_until, fn cell, lit_until ->
            lit_until =
              if cell in arrivals, do: Map.put(lit_until, cell, tick + 8), else: lit_until

            ink = if Map.get(lit_until, cell, 0) > tick, do: 3, else: 0
            {{cell, ink}, lit_until}
          end)

        send(caller, {ref, marks})
        paint_row(cells, reveal_at, lit_until)
    end
  end
end
