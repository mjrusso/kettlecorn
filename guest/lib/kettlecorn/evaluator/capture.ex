defmodule Kettlecorn.Evaluator.Capture do
  @moduledoc false
  # Track descendants separately from I/O so output floods cannot delay cleanup.
  # Run guest callbacks in tracked workers. Guest code can replace its tracer
  # or kill the tracker; VM limits provide the isolation boundary.

  @max_output 1_000_000

  def max_output, do: @max_output

  def start(stdout) do
    {tracker, tracker_ref} =
      spawn_monitor(fn ->
        # High priority lets the tracker keep up with continuous process spawning.
        Process.flag(:priority, :high)

        receive do: ({:leader, leader} ->
                       track_loop(%{mode: :capture, leader: leader, live: MapSet.new()}))
      end)

    {leader, leader_ref} =
      spawn_monitor(fn ->
        leader_loop(%{
          mode: :capture,
          output: [],
          size: 0,
          truncated: false,
          stdout: stdout,
          tracker: tracker,
          # monitor ref => {pid, from, reply_as}
          workers: %{}
        })
      end)

    send(tracker, {:leader, leader})
    %{leader: leader, tracker: tracker, monitors: %{leader_ref => leader, tracker_ref => tracker}}
  end

  def run(capture, pid), do: send(capture.tracker, {:run, pid})

  def finish(capture, mode, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    capture = Map.merge(capture, %{mode: mode, deadline: deadline, timeout: timeout})
    if mode == :kill, do: send(capture.tracker, :kill)

    case call(capture.leader, {:finish, mode}, remaining(deadline)) do
      {:ok, output} -> finish_tracker(capture, output)
      _unavailable -> {{"", false}, teardown(capture)}
    end
  end

  defp finish_tracker(%{mode: :kill} = capture, output), do: {output, capture}

  defp finish_tracker(capture, output) do
    case call(capture.tracker, :forward, remaining(capture.deadline)) do
      {:ok, :ok} -> {output, capture}
      _unavailable -> {output, teardown(capture)}
    end
  end

  # The evaluator tail-calls this after replying. Collect its completed result
  # before forwarding descendants can keep the coordinator idle indefinitely.
  def await(capture) do
    :erlang.garbage_collect()
    await_down(capture)
  end

  defp await_down(capture) when map_size(capture.monitors) == 0, do: :ok

  defp await_down(capture) do
    timeout = if capture.mode == :forward, do: :infinity, else: remaining(capture.deadline)

    receive do
      {:DOWN, ref, :process, pid, reason} when is_map_key(capture.monitors, ref) ->
        capture = %{capture | monitors: Map.delete(capture.monitors, ref)}
        capture = capture_down(capture, pid, reason)
        await_down(capture)
    after
      timeout ->
        Enum.each(capture.monitors, fn {_ref, pid} -> Process.exit(pid, :kill) end)
        :ok
    end
  end

  defp capture_down(%{mode: :forward, tracker: tracker} = capture, tracker, :normal) do
    %{capture | mode: :kill, deadline: System.monotonic_time(:millisecond) + capture.timeout}
  end

  defp capture_down(%{mode: :forward} = capture, _pid, _reason), do: teardown(capture)
  defp capture_down(capture, _pid, _reason), do: capture

  defp teardown(capture) do
    Process.exit(capture.leader, :kill)
    send(capture.tracker, :kill)
    %{capture | mode: :kill, deadline: System.monotonic_time(:millisecond) + capture.timeout}
  end

  defp remaining(deadline), do: max(0, deadline - System.monotonic_time(:millisecond))

  defp call(pid, request, timeout) do
    ref = Process.monitor(pid)
    send(pid, {request, self(), ref})

    receive do
      {^ref, reply} ->
        Process.demonitor(ref, [:flush])
        {:ok, reply}

      {:DOWN, ^ref, :process, ^pid, _reason} ->
        :down
    after
      timeout ->
        Process.demonitor(ref, [:flush])
        :timeout
    end
  end

  defp leader_loop(s) do
    receive do
      {:io_request, from, reply_as, request} ->
        leader_loop(io_request(s, from, reply_as, request))

      {:DOWN, ref, :process, _pid, reason} when is_map_key(s.workers, ref) ->
        leader_loop(worker_done(s, ref, reason))

      # Workers still waiting to run exit with the leader.
      {{:finish, :kill}, from, ref} when s.mode == :capture ->
        send(from, {ref, output(s)})

      {{:finish, :forward}, from, ref} when s.mode == :capture ->
        send(from, {ref, output(s)})
        leader_loop(%{s | mode: :forward, output: [], size: 0})

      # A worker's {:run, pid} can arrive after the tracker sends :done.
      # Kill workers that never received :go; collect the others' exit results.
      :done ->
        Enum.reduce(s.workers, s, fn {ref, {pid, _from, _reply_as}}, s ->
          Process.exit(pid, :kill)
          receive do: ({:DOWN, ^ref, :process, _pid, reason} -> worker_done(s, ref, reason))
        end)

      _other ->
        leader_loop(s)
    end
  end

  defp output(s) do
    output = s.output |> Enum.reverse() |> IO.iodata_to_binary()
    {if(s.truncated, do: complete_utf8(output), else: output), s.truncated}
  end

  defp complete_utf8(output) do
    size = byte_size(output)
    n = Enum.find(0..min(3, size), 0, &String.valid?(binary_part(output, 0, size - &1)))
    binary_part(output, 0, size - n)
  end

  defp io_request(%{mode: :forward} = s, from, reply_as, request) do
    send(s.stdout, {:io_request, from, reply_as, request})
    s
  end

  defp io_request(s, from, reply_as, request) do
    case parse(request) do
      {:output, pieces} ->
        if Enum.all?(pieces, &match?({_encoding, _chars}, &1)),
          do: write(s, from, reply_as, pieces),
          else: start_worker(s, from, reply_as, pieces)

      {:reply, reply} ->
        send(from, {:io_reply, reply_as, reply})
        s
    end
  end

  defp write(s, from, reply_as, pieces) do
    case to_binary(pieces) do
      {:ok, data} ->
        send(from, {:io_reply, reply_as, :ok})
        append(s, data)

      :error ->
        send(from, {:io_reply, reply_as, {:error, :put_chars}})
        s
    end
  end

  defp parse({:put_chars, encoding, chars}), do: {:output, [{encoding, chars}]}
  defp parse({:put_chars, encoding, m, f, a}), do: {:output, [{encoding, m, f, a}]}
  defp parse({:put_chars, chars}), do: {:output, [{:latin1, chars}]}
  defp parse({:put_chars, m, f, a}), do: {:output, [{:latin1, m, f, a}]}

  defp parse({:requests, requests}) when is_list(requests) do
    with true <- proper_list?(requests),
         {:output, reversed} <- Enum.reduce_while(requests, {:output, []}, &add_request/2) do
      {:output, reversed |> Enum.reverse() |> Enum.concat()}
    else
      _ -> {:reply, {:error, :request}}
    end
  end

  defp parse(request)
       when is_tuple(request) and
              elem(request, 0) in [:get_chars, :get_line, :get_until, :get_password],
       do: {:reply, :eof}

  defp parse({:setopts, _opts}), do: {:reply, :ok}
  defp parse(:getopts), do: {:reply, [binary: true, encoding: :unicode]}
  defp parse({:get_geometry, _}), do: {:reply, {:error, :enotsup}}
  defp parse(_request), do: {:reply, {:error, :request}}

  defp add_request(request, {:output, reversed}) do
    case parse(request) do
      {:output, pieces} -> {:cont, {:output, [pieces | reversed]}}
      {:reply, _reply} -> {:halt, :error}
    end
  end

  defp proper_list?([]), do: true
  defp proper_list?([_ | tail]), do: proper_list?(tail)
  defp proper_list?(_tail), do: false

  # Convert in the worker: guest callbacks can exit with a forged result,
  # so the leader must accept only binaries and never traverse returned data.
  defp start_worker(s, from, reply_as, pieces) do
    leader = self()

    {pid, ref} =
      spawn_monitor(fn ->
        monitor = Process.monitor(leader)

        receive do
          :go -> exit({:output, to_binary(Enum.map(pieces, &apply_piece/1))})
          {:DOWN, ^monitor, :process, ^leader, _reason} -> :ok
        end
      end)

    send(s.tracker, {:run, pid})
    %{s | workers: Map.put(s.workers, ref, {pid, from, reply_as})}
  end

  defp apply_piece({encoding, m, f, a}), do: {encoding, apply(m, f, a)}
  defp apply_piece(piece), do: piece

  defp worker_done(s, ref, reason) do
    {{_pid, from, reply_as}, workers} = Map.pop(s.workers, ref)
    s = %{s | workers: workers}

    case {reason, s.mode} do
      {{:output, {:ok, data}}, :capture} when is_binary(data) ->
        send(from, {:io_reply, reply_as, :ok})
        append(s, data)

      {{:output, {:ok, data}}, _forward} when is_binary(data) ->
        send(s.stdout, {:io_request, from, reply_as, {:put_chars, :unicode, data}})
        s

      _error ->
        send(from, {:io_reply, reply_as, {:error, :put_chars}})
        s
    end
  end

  defp to_binary(pieces) do
    result =
      Enum.reduce_while(pieces, {:ok, []}, fn {encoding, chars}, {:ok, acc} ->
        case :unicode.characters_to_binary(chars, encoding, :unicode) do
          data when is_binary(data) -> {:cont, {:ok, [acc | data]}}
          _incomplete_or_error -> {:halt, :error}
        end
      end)

    with {:ok, iodata} <- result, do: {:ok, IO.iodata_to_binary(iodata)}
  rescue
    ArgumentError -> :error
  end

  # Empty writes must not allocate list cells, including after the cap.
  defp append(s, ""), do: s
  defp append(%{size: @max_output} = s, _data), do: %{s | truncated: true}

  defp append(%{size: size} = s, data) when size + byte_size(data) <= @max_output,
    do: %{s | output: [data | s.output], size: size + byte_size(data)}

  defp append(s, data) do
    # A slice would keep the entire write alive after truncation.
    kept = :binary.copy(binary_part(data, 0, @max_output - s.size))
    %{s | output: [kept | s.output], size: @max_output, truncated: true}
  end

  defp track_loop(%{mode: :forward} = s) do
    if MapSet.size(s.live) == 0 do
      # Pending trace messages may still report new processes.
      s = drain(s)
      if MapSet.size(s.live) == 0, do: send(s.leader, :done), else: track_step(s)
    else
      track_step(s)
    end
  end

  defp track_loop(s), do: track_step(s)

  defp track_step(s) do
    receive do
      :kill ->
        kill_all(s)

      {:forward, from, ref} ->
        send(from, {ref, :ok})
        track_loop(%{s | mode: :forward})

      message ->
        track_loop(track(message, s))
    end
  end

  # pid waits for :go, so that every process it starts inherits the group
  # leader and the tracing, and is tracked here before its own :exit can
  # arrive.
  defp lead(pid, s) do
    Process.group_leader(pid, s.leader)
    :erlang.trace(pid, true, [:procs, :set_on_spawn, {:tracer, self()}])
    send(pid, :go)
    %{s | live: MapSet.put(s.live, pid)}
  end

  # Max priority prevents normal-priority descendants from spawning faster
  # than cleanup kills them. Do not block until all known targets are killed;
  # drain/1 then waits for trace messages still in transit.
  defp kill_all(s) do
    Process.flag(:priority, :max)
    kill_rounds(s, MapSet.new())
  end

  defp kill_rounds(s, killed) do
    s = collect(s)
    targets = MapSet.difference(s.live, killed)

    if MapSet.size(targets) > 0 do
      Enum.each(targets, &Process.exit(&1, :kill))
      kill_rounds(s, MapSet.union(killed, targets))
    else
      s = drain(s)
      if not MapSet.subset?(s.live, killed), do: kill_rounds(s, killed)
    end
  end

  defp collect(s) do
    receive do
      {:run, _pid} = message -> collect(track(message, s))
      {:trace, _pid, _event, _info} = message -> collect(track(message, s))
      {:trace, _pid, _event, _info, _extra} = message -> collect(track(message, s))
    after
      0 -> s
    end
  end

  defp drain(s) do
    ref = :erlang.trace_delivered(:all)
    drain(ref, s)
  end

  defp drain(ref, s) do
    receive do
      {:trace_delivered, :all, ^ref} -> s
      {:run, _pid} = message -> drain(ref, track(message, s))
      {:trace, _pid, _event, _info} = message -> drain(ref, track(message, s))
      {:trace, _pid, _event, _info, _extra} = message -> drain(ref, track(message, s))
    end
  end

  # Each traced process reports its own :spawned and :exit, in that order.
  defp track({:run, pid}, s), do: lead(pid, s)
  defp track({:trace, pid, :spawned, _parent, _mfa}, s), do: %{s | live: MapSet.put(s.live, pid)}
  defp track({:trace, pid, :exit, _reason}, s), do: %{s | live: MapSet.delete(s.live, pid)}
  defp track(_other, s), do: s
end
