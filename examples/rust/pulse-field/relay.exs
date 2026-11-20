defmodule Bot do
  @handoff_delay 16
  @radii [5, 8, 11, 14]

  def init(%{"center" => {cx, cy}}) do
    actors =
      for {radius, id} <- Enum.with_index(@radii, 1) do
        track = square(cx, cy, radius)
        start = div((id - 1) * tuple_size(track), length(@radii))
        pid = spawn_link(fn -> setup(id, track, start) end)
        {id, pid}
      end

    successors = Enum.drop(actors, 1) ++ Enum.take(actors, 1)

    for {{_, pid}, next} <- Enum.zip(actors, successors) do
      send(pid, {:successor, next})
    end

    actors
  end

  def frame(%{"tick" => tick, "pulses" => pulses}, actors) do
    requests =
      for {_, pid} <- actors do
        ref = make_ref()
        send(pid, {:step, self(), ref, tick})
        ref
      end

    {positions, messages} =
      Enum.reduce(requests, {[], []}, fn ref, {positions, messages} ->
        receive do
          {^ref, position, nil} -> {[position | positions], messages}
          {^ref, position, handoff} -> {[position | positions], [handoff | messages]}
        end
      end)

    mirrors = for {_id, cell, _ink, mirror} <- positions, mirror, into: %{}, do: {cell, mirror}

    turns =
      for {id, cell, {dx, dy}} <- pulses, mirror = mirrors[cell] do
        direction = if mirror == :slash, do: {-dy, -dx}, else: {dy, dx}
        {id, direction}
      end

    {%{"turns" => turns, "actors" => positions, "messages" => messages}, actors}
  end

  defp square(cx, cy, radius) do
    left = cx - radius
    right = cx + radius
    top = cy - radius
    bottom = cy + radius

    (Enum.map(left..(right - 1), &{&1, top}) ++
       Enum.map(top..(bottom - 1), &{right, &1}) ++
       Enum.map(right..(left + 1)//-1, &{&1, bottom}) ++
       Enum.map(bottom..(top + 1)//-1, &{left, &1}))
    |> List.to_tuple()
  end

  defp setup(id, track, start) do
    receive do
      {:successor, next} ->
        listen({id, track, next}, start, 1, if(id == 1, do: @handoff_delay))
    end
  end

  defp listen({id, track, {next_id, next_pid}} = route, index, direction, handoff_at) do
    receive do
      {:step, caller, ref, tick} ->
        {direction, handoff_at} =
          receive do
            {:baton, sent_at} when sent_at < tick -> {-direction, tick + @handoff_delay}
          after
            0 -> {direction, handoff_at}
          end

        index =
          if rem(tick, 2) == 0, do: Integer.mod(index + direction, tuple_size(track)), else: index

        mirror = if handoff_at, do: if(direction == 1, do: :slash, else: :backslash)
        position = {id, elem(track, index), rem(id - 1, 4), mirror}

        if tick == handoff_at do
          send(next_pid, {:baton, tick})
          send(caller, {ref, position, {id, next_id, nil}})
          listen(route, index, direction, nil)
        else
          send(caller, {ref, position, nil})
          listen(route, index, direction, handoff_at)
        end
    end
  end
end
