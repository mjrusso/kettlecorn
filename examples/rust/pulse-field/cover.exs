defmodule Bot do
  @workers 2
  @help_at_charge 1
  @charge 3
  @health 2

  defstruct [:id, :cell, :home, mode: :rest, charge: @charge, health: @health]

  def init(%{"center" => {cx, cy}}) do
    for id <- 1..@workers//1 do
      home = {cx - 5 - rem((id - 1) * 2, 10), cy + 4 + rem(id, 6)}
      cell = if id == 1, do: {cx - 5, cy}, else: home
      mode = if id == 1, do: :cover, else: :rest
      worker = %__MODULE__{id: id, cell: cell, home: home, mode: mode}
      {id, spawn_link(fn -> listen(worker) end), status(worker)}
    end
  end

  def frame(%{"tick" => tick, "pulses" => pulses, "emitters" => emitters}, crew) do
    alive = MapSet.new(crew, fn {id, _, _} -> id end)
    lead = if Enum.all?(crew, fn {_, _, status} -> status != :engaged end), do: ready(crew)

    lanes =
      if emitters == [],
        do: Enum.map(pulses, fn {_, cell, dir} -> {cell, dir} end),
        else: emitters

    moves =
      ask(crew, fn {id, _, _} ->
        {:move, tick, lanes, alive, match?({^id, _, _}, lead)}
      end)

    cells =
      Enum.reduce(moves, %{}, fn {id, _, {cell, raised, _}}, cells ->
        Map.update(cells, cell, {id, raised}, fn
          {_, false} when raised -> {id, raised}
          occupant -> occupant
        end)
      end)

    contacts =
      Enum.group_by(pulses, fn {_, cell, _} ->
        case cells[cell] do
          {id, _} -> id
          nil -> nil
        end
      end)

    results =
      ask(crew, fn {id, _, _} ->
        {:impact, tick, Map.get(contacts, id, []), ready(crew, id), MapSet.size(alive) == 1}
      end)

    actors = for {_, _, {actor, _, _, _}} <- results, actor, do: actor
    moved = for {_, _, {_, _, signal}} <- moves, signal, do: signal
    requested = for {_, _, {_, _, signal, _}} <- results, signal, do: signal
    hits = Enum.flat_map(results, fn {_, _, {_, hits, _, _}} -> hits end)
    next = for {id, pid, {actor, _, _, status}} <- results, actor, do: {id, pid, status}
    {%{"actors" => actors, "messages" => moved ++ requested, "hits" => hits}, next}
  end

  defp ready(crew, after_id \\ 0) do
    crew
    |> Enum.filter(fn {id, _, status} -> id != after_id and status == :ready end)
    |> Enum.min_by(fn {id, _, _} -> {id <= after_id, id} end, fn -> nil end)
  end

  defp ask(crew, command) do
    requests =
      for {id, pid, _} = actor <- crew do
        ref = make_ref()
        send(pid, {self(), ref, command.(actor)})
        {id, pid, ref}
      end

    for {id, pid, ref} <- requests do
      receive do
        {^ref, reply} -> {id, pid, reply}
      end
    end
  end

  defp listen(worker) do
    receive do
      {caller, ref, {:move, tick, lanes, alive, lead}} ->
        worker = inbox(worker, tick)

        worker =
          case worker.mode do
            :rest when lead ->
              %{worker | mode: :cover}

            {:waiting, id} ->
              if MapSet.member?(alive, id), do: worker, else: %{worker | mode: :cover}

            _ ->
              worker
          end

        {worker, signal} = walk(worker, lanes, tick)
        send(caller, {ref, {worker.cell, raised?(worker), signal}})
        listen(worker)

      {caller, ref, {:impact, tick, contacts, helper, alone}} ->
        {worker, hits} = absorb(worker, contacts)

        if worker.health == 0 do
          send(caller, {ref, {nil, hits, nil, :dead}})
        else
          {worker, signal} = request_cover(worker, helper, contacts, tick, alone)
          worker = recharge(worker, tick)
          shield = {:shield, raised?(worker), worker.charge, worker.health}
          actor = {worker.id, worker.cell, ink(worker), shield}
          status = status(worker)
          send(caller, {ref, {actor, hits, signal, status}})
          listen(worker)
        end
    end
  end

  defp inbox(worker, tick) do
    receive do
      {:cover_me, sent, id, pid, lane} when sent < tick ->
        worker =
          if worker.mode == :rest do
            %{worker | mode: {:relieve, id, pid, project(worker.home, lane)}}
          else
            worker
          end

        inbox(worker, tick)

      {:in_position, sent, id} when sent < tick ->
        worker = if worker.mode == {:waiting, id}, do: %{worker | mode: :rest}, else: worker
        inbox(worker, tick)
    after
      0 -> worker
    end
  end

  defp walk(%{mode: {:relieve, id, pid, target}} = worker, _, tick) do
    cell = step(worker.cell, target)

    if cell == target do
      send(pid, {:in_position, tick, worker.id})
      {%{worker | cell: cell, mode: :cover}, {worker.id, id, :in_position}}
    else
      {%{worker | cell: cell}, nil}
    end
  end

  defp walk(%{mode: :rest} = worker, _, _),
    do: {%{worker | cell: step(worker.cell, worker.home)}, nil}

  defp walk(%{mode: :cover} = worker, lanes, _) do
    {x, y} = worker.cell

    destination =
      lanes
      |> Enum.map(&project(worker.cell, &1))
      |> Enum.min_by(fn {tx, ty} -> abs(tx - x) + abs(ty - y) end, fn -> worker.cell end)

    {%{worker | cell: step(worker.cell, destination)}, nil}
  end

  defp walk(worker, _, _), do: {worker, nil}

  defp project({x, _}, {{_, lane}, {dx, 0}}) when dx != 0, do: {x, lane}
  defp project({_, y}, {{lane, _}, {0, dy}}) when dy != 0, do: {lane, y}
  defp project(_, {cell, _}), do: cell

  defp step({x, y}, {tx, _}) when x != tx, do: {x + sign(tx - x), y}
  defp step({x, y}, {_, ty}), do: {x, y + sign(ty - y)}
  defp sign(value) when value < 0, do: -1
  defp sign(0), do: 0
  defp sign(_), do: 1

  defp absorb(worker, contacts) do
    Enum.reduce_while(contacts, {worker, []}, fn {id, _, _}, {worker, hits} ->
      {worker, kind} =
        if raised?(worker) and worker.charge > 0 do
          {%{worker | charge: worker.charge - 1}, :shield}
        else
          {%{worker | health: worker.health - 1}, :damage}
        end

      reply = {worker, [{id, ink(worker), kind} | hits]}
      if worker.health == 0, do: {:halt, reply}, else: {:cont, reply}
    end)
  end

  defp request_cover(
         %{mode: :cover, charge: charge} = worker,
         {id, pid, _},
         [{_, _, direction} | _],
         tick,
         _
       )
       when charge <= @help_at_charge do
    send(pid, {:cover_me, tick, worker.id, self(), {worker.cell, direction}})
    {%{worker | mode: {:waiting, id}}, {worker.id, id, :cover_me}}
  end

  defp request_cover(%{mode: :cover, charge: 0} = worker, _, _, _, true),
    do: {%{worker | mode: :rest}, nil}

  defp request_cover(worker, _, _, _, _), do: {worker, nil}

  defp recharge(worker, tick) do
    if rem(tick, 4) == 0 and not raised?(worker) do
      %{worker | charge: min(@charge, worker.charge + 1)}
    else
      worker
    end
  end

  defp status(%{mode: :rest, charge: @charge}), do: :ready
  defp status(%{mode: :rest}), do: :recharging
  defp status(_), do: :engaged

  defp raised?(worker), do: worker.mode == :cover or match?({:waiting, _}, worker.mode)
  defp ink(worker), do: rem(worker.id - 1, 4)
end
