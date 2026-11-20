defmodule Bot do
  def init(%{"size" => size}) do
    cells =
      for y <- 0..(size - 1), x <- 0..(size - 1), into: %{} do
        cell = {x, y}
        {cell, spawn_link(fn -> setup(cell) end)}
      end

    for {{x, y} = cell, pid} <- cells do
      neighbors =
        [{x - 1, y}, {x + 1, y}, {x, y - 1}, {x, y + 1}]
        |> Enum.flat_map(fn neighbor ->
          case cells do
            %{^neighbor => pid} -> [pid]
            _ -> []
          end
        end)

      send(pid, {:neighbors, neighbors})
    end

    cells
  end

  def frame(%{"tick" => tick, "pulses" => pulses}, cells) do
    requests =
      pulses
      |> Enum.group_by(fn {_id, cell, _direction} -> cell end)
      |> Enum.map(fn {cell, arrivals} ->
        ref = make_ref()
        send(Map.fetch!(cells, cell), {:arrivals, tick, arrivals, self(), ref})
        ref
      end)

    {turns, marks} =
      Enum.reduce(requests, {[], []}, fn ref, {turns, marks} ->
        receive do
          {^ref, changes, mark} -> {changes ++ turns, [mark | marks]}
        end
      end)

    {%{"turns" => turns, "marks" => marks}, cells}
  end

  defp setup({x, y} = cell) do
    receive do
      {:neighbors, neighbors} ->
        mirror = rem(x, 4) == 2 and rem(y, 4) == 2
        slash = rem(div(x, 4) + div(y, 4), 2) == 0
        listen({cell, neighbors, mirror, slash}, false, {0, false})
    end
  end

  defp listen({cell, neighbors, mirror, slash} = settings, flipped, pending) do
    receive do
      {:flip, tick} ->
        {flipped, {_, flip}} = apply_before(flipped, pending, tick)
        listen(settings, flipped, {tick, not flip})

      {:arrivals, tick, arrivals, caller, ref} ->
        {flipped, pending} = apply_before(flipped, pending, tick)

        {turns, ink} =
          if mirror or flipped do
            for pid <- neighbors, do: send(pid, {:flip, tick})

            turns =
              for {id, _, {dx, dy}} <- arrivals do
                direction = if slash != flipped, do: {-dy, -dx}, else: {dy, dx}
                {id, direction}
              end

            {turns, if(flipped, do: 2, else: 1)}
          else
            {[], 0}
          end

        send(caller, {ref, turns, {cell, ink}})
        listen(settings, flipped, pending)
    end
  end

  defp apply_before(flipped, {previous, flip}, tick) when previous < tick,
    do: {flipped != flip, {tick, false}}

  defp apply_before(flipped, pending, _tick), do: {flipped, pending}
end
