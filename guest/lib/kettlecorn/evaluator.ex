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

  Replies contain the formatted result, captured output and, for bounded
  plain data, the result as a term.
  """
  use GenServer

  alias Kettlecorn.Evaluator.Capture

  @max_value_terms 1_000_000

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
    spawn(fn -> evaluate(code, opts, from) end)
    {:noreply, state}
  end

  def handle_call(_other, _from, state), do: {:reply, {:error, %{"kind" => "badarg"}}, state}

  defp evaluate(
         code,
         %{"timeout_ms" => timeout, "finish_timeout_ms" => finish_timeout, "language" => language} =
           opts,
         from
       ) do
    language = Map.fetch!(@languages, language)
    binding = opts |> Map.get("binding", %{}) |> Enum.map(fn {k, v} -> {String.to_atom(k), v} end)
    parent = self()
    capture = Capture.start(Process.group_leader())

    # Formatting and checking the result must also run under the timeout.
    {pid, ref} =
      spawn_monitor(fn ->
        receive do: (:go -> :ok)

        reply =
          try do
            case language.eval(code, binding) do
              {:ok, value} -> success(value, language.inspected(value))
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
        {:reply, ^pid, reply} ->
          Process.demonitor(ref, [:flush])
          {reply, :forward}

        # A forged exit reason can run guest exception or Inspect callbacks.
        # Format it without those callbacks so timeout handling cannot block.
        {:DOWN, ^ref, :process, ^pid, reason} ->
          reply = failure(:exit, "the evaluation exited: " <> inspect(reason, structs: false))
          {reply, :forward}
      after
        timeout ->
          # Kill the evaluation directly: guest code can kill its tracker.
          Process.exit(pid, :kill)
          Process.demonitor(ref, [:flush])

          {failure(:timeout, "evaluation timed out"), :kill}
      end

    {output, capture} = Capture.finish(capture, mode, finish_timeout)
    GenServer.reply(from, with_output(reply, output))
    Capture.await(capture)
  end

  defp with_output({status, reply}, {output, truncated}) do
    reply = Map.put(reply, "output", output)
    if truncated, do: {status, Map.put(reply, "output_truncated", true)}, else: {status, reply}
  end

  defp success(value, inspected) do
    reply = %{"inspected" => inspected}
    if plain?(value), do: {:ok, Map.put(reply, "value", value)}, else: {:ok, reply}
  end

  defp failure(kind, message),
    do: {:error, %{"kind" => Atom.to_string(kind), "message" => message}}

  # Shared subterms can make traversal exponential in construction time
  # (e.g. Enum.reduce(1..40, :x, &{&2, &2})); bound the nodes visited.
  defp plain?(value), do: walk(value, @max_value_terms) != :no

  defp walk(_value, 0), do: :no
  defp walk(v, n) when is_number(v) or is_binary(v) or is_atom(v), do: n - 1
  defp walk(v, n) when is_list(v), do: walk_list(v, n - 1)
  defp walk(v, n) when is_tuple(v), do: walk_list(Tuple.to_list(v), n - 1)
  # Avoid protocol dispatch on guest structs.
  defp walk(v, n) when is_map(v), do: walk_list(Map.to_list(v), n - 1)
  defp walk(_value, _n), do: :no

  defp walk_list([], n), do: n

  defp walk_list([head | tail], n) do
    case walk(head, n) do
      :no -> :no
      n -> walk_list(tail, n)
    end
  end

  defp walk_list(_improper, _n), do: :no
end
