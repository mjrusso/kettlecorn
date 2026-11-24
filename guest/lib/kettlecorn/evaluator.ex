defmodule Kettlecorn.Evaluator do
  @name :kettlecorn_evaluator

  @moduledoc """
  Evaluates Elixir or Erlang source inside the WASI VM on behalf of the host.

  The host calls this GenServer through `Kettlecorn.Proxy`. Each evaluation
  runs in a fresh process with output captured by `Kettlecorn.Evaluator.Capture`
  (up to #{Kettlecorn.Evaluator.Capture.max_output()} bytes).

  On success, descendants keep running and later output goes to VM stdout.
  On timeout or capture failure, the capture attempts to kill descendants.
  Guest code can interfere with tracing; VM limits remain necessary for
  untrusted code.

  An evaluation, the processes it spawns and the workers that run its output
  callbacks are charged to one reduction budget (OTP patch 0108). Past
  `"max_reductions"`, the scheduler kills them, and the evaluation fails
  with kind `reductions`.

  Replies contain the formatted result, captured output, the reductions
  used and, for bounded plain data, the result as a term.
  """
  use GenServer

  alias Kettlecorn.Evaluator.Capture

  # The budget counts in a signed 64-bit integer.
  @max_reductions 0x7FFF_FFFF_FFFF_FFFF
  @max_value_terms 1_000_000
  @max_value_depth 508

  @languages %{"elixir" => Kettlecorn.Evaluator.Elixir, "erlang" => Kettlecorn.Evaluator.Erlang}

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: @name)

  @impl true
  def init(nil), do: {:ok, %{}}

  @impl true
  def handle_call(
        {:eval, code,
         %{"timeout_ms" => _, "finish_timeout_ms" => _, "language" => language} = opts},
        from,
        state
      )
      when is_binary(code) and is_map_key(@languages, language) do
    case Map.get(opts, "max_reductions", :infinity) do
      limit when limit == :infinity or (is_integer(limit) and limit in 1..@max_reductions) ->
        spawn(fn -> evaluate(code, opts, limit, from) end)
        {:noreply, state}

      _ ->
        {:reply, {:error, %{"kind" => "badarg"}}, state}
    end
  end

  def handle_call(_other, _from, state), do: {:reply, {:error, %{"kind" => "badarg"}}, state}

  defp evaluate(
         code,
         %{"timeout_ms" => timeout, "finish_timeout_ms" => finish_timeout, "language" => language} =
           opts,
         max_reductions,
         from
       ) do
    language = Map.fetch!(@languages, language)
    binding = opts |> Map.get("binding", %{}) |> Enum.map(fn {k, v} -> {String.to_atom(k), v} end)
    parent = self()
    budget = :wasm.reduction_budget(max_reductions)
    capture = Capture.start(Process.group_leader(), budget)
    {terms, depth, bytes} = value_limits(opts)
    deadline = deadline(timeout)

    # Formatting and checking the result must also run under the timeout
    # and the reduction budget.
    {pid, ref} =
      spawn_monitor(fn ->
        :ok = :wasm.attach_reduction_budget(budget)
        receive do: (:go -> :ok)

        reply =
          try do
            case language.eval(code, binding) do
              {:ok, value} -> success(value, language.inspected(value), terms, depth)
              {:error, kind, message} -> failure(kind, message)
            end
          catch
            kind, reason -> failure(kind, language.message(kind, reason, __STACKTRACE__))
          end

        send(parent, {:reply, self(), reply})
      end)

    Capture.run(capture, pid)

    {reply, mode} =
      receive do
        # Wait for DOWN before closing the budget. The scheduler can still
        # charge the evaluation after it sends its reply.
        {:reply, ^pid, reply} ->
          receive do
            {:DOWN, ^ref, :process, ^pid, _reason} -> {reply, :forward}
          after
            remaining(deadline) -> kill(pid, ref)
          end

        # A forged exit reason can run guest exception or Inspect callbacks.
        # Format it without those callbacks so timeout handling cannot block.
        {:DOWN, ^ref, :process, ^pid, reason} ->
          reply = failure(:exit, "the evaluation exited: " <> inspect(reason, structs: false))
          {reply, :forward}
      after
        remaining(deadline) -> kill(pid, ref)
      end

    {{reply, mode}, reductions} =
      case :wasm.close_reduction_budget(budget) do
        {used, true} ->
          {{failure(:reductions, "evaluation exceeded its reduction limit"), :kill}, used}

        {used, false} ->
          {{reply, mode}, used}
      end

    {output, capture} = Capture.finish(capture, mode, finish_timeout)

    reply =
      reply
      |> with_output(output)
      |> put_field("reductions", reductions)
      |> limit_value_bytes(bytes)

    GenServer.reply(from, reply)
    Capture.await(capture)
  end

  # Kill the evaluation directly: guest code can kill its tracker.
  defp kill(pid, ref) do
    Process.exit(pid, :kill)
    Process.demonitor(ref, [:flush])
    {failure(:timeout, "evaluation timed out"), :kill}
  end

  defp deadline(:infinity), do: :infinity
  defp deadline(timeout), do: System.monotonic_time(:millisecond) + timeout

  defp remaining(:infinity), do: :infinity
  defp remaining(deadline), do: max(0, deadline - System.monotonic_time(:millisecond))

  defp put_field({status, reply}, key, value), do: {status, Map.put(reply, key, value)}

  defp with_output({status, reply}, {output, truncated}) do
    reply = Map.put(reply, "output", output)
    if truncated, do: {status, Map.put(reply, "output_truncated", true)}, else: {status, reply}
  end

  defp limit_value_bytes({:ok, %{"value" => _} = reply} = result, limit)
       when is_integer(limit) do
    if :erlang.external_size(result) > limit,
      do: {:ok, Map.delete(reply, "value")},
      else: result
  end

  defp limit_value_bytes(result, _limit), do: result

  defp success(value, inspected, terms, depth) do
    reply = %{"inspected" => inspected}

    if walk(value, terms, depth) == :no,
      do: {:ok, reply},
      else: {:ok, Map.put(reply, "value", value)}
  end

  defp failure(kind, message),
    do: {:error, %{"kind" => Atom.to_string(kind), "message" => message}}

  # Shared subterms can make traversal exponential in construction time
  # (e.g. Enum.reduce(1..40, :x, &{&2, &2})); bound the nodes visited.
  defp value_limits(%{"value_limits" => {terms, depth, bytes}})
       when is_integer(terms) and terms > 0 and is_integer(depth) and depth >= 0 and
              is_integer(bytes) and bytes > 0 do
    {min(terms, @max_value_terms), min(depth, @max_value_depth), bytes}
  end

  defp value_limits(_opts), do: {@max_value_terms, @max_value_depth, nil}

  defp walk(_value, n, depth) when n <= 0 or depth < 0, do: :no
  defp walk(v, n, _depth) when is_number(v) or is_binary(v) or is_atom(v), do: n - 1
  defp walk(v, n, depth) when is_list(v), do: walk_list(v, n - 1, depth - 1)
  defp walk(v, n, depth) when is_tuple(v), do: walk_list(Tuple.to_list(v), n - 1, depth - 1)
  # Avoid protocol dispatch on guest structs.
  defp walk(v, n, depth) when is_map(v), do: walk_pairs(:maps.iterator(v), n - 1, depth - 1)
  defp walk(_value, _n, _depth), do: :no

  defp walk_list([], n, _depth), do: n

  defp walk_list([head | tail], n, depth) do
    case walk(head, n, depth) do
      :no -> :no
      n -> walk_list(tail, n, depth)
    end
  end

  defp walk_list(_improper, _n, _depth), do: :no

  defp walk_pairs(iterator, n, depth) do
    case :maps.next(iterator) do
      :none ->
        n

      {key, value, rest} ->
        with n when is_integer(n) <- walk(key, n - 1, depth),
             n when is_integer(n) <- walk(value, n, depth) do
          walk_pairs(rest, n, depth)
        end
    end
  end
end
