defmodule Kettlecorn.Preload do
  @moduledoc false
  # Load modules serially so parallel preparation cannot reorder atom creation.

  alias Kettlecorn.Event

  def mode do
    case :init.get_argument(:kettlecorn_preload) do
      {:ok, [[~c"strict"]]} -> :strict
      {:ok, _} -> :on
      :error -> :off
    end
  end

  def run(:off), do: :ok

  def run(mode) do
    case Enum.find_value(modules(), &load/1) do
      nil ->
        # Without framing, the bridge drops event frames.
        framed = System.get_env("KETTLECORN_FRAMED") == "1"
        :persistent_term.put(:kettlecorn_late_load, spawn(fn -> report(mode, framed) end))
        :ok

      failure ->
        failure
    end
  end

  defp modules do
    for({name, _file, false} <- :code.all_available(), do: List.to_atom(name))
    |> Enum.sort()
  end

  defp load(module) do
    case :code.ensure_loaded(module) do
      {:module, ^module} -> nil
      error -> {"preloading #{module}", error}
    end
  end

  # The code server sends the barrier after earlier reports. Wait for the
  # reporter to reach it so normal CLI shutdown cannot lose a strict-mode failure.
  def flush do
    reporter = :persistent_term.get(:kettlecorn_late_load)
    ref = Process.monitor(reporter)
    :ok = :code_server.call({:kettlecorn_late_load_barrier, ref})

    receive do
      {^ref, :flushed} -> Process.demonitor(ref, [:flush])
      {:DOWN, ^ref, _, _, _} -> :ok
    end

    :ok
  end

  defp report(mode, framed) do
    receive do
      {:kettlecorn_late_load, module} -> late_load(module, mode, framed)
      {:kettlecorn_late_load_barrier, from, ref} -> send(from, {ref, :flushed})
    end

    report(mode, framed)
  end

  defp late_load(module, mode, framed) do
    name = Atom.to_string(module)
    if framed, do: Event.send(%{event: :late_load, module: name})

    if mode == :strict or not framed,
      do: :io.format(:standard_error, "kettlecorn: ~ts was loaded after preload~n", [name])

    if mode == :strict, do: :erlang.halt(1)
  end
end
