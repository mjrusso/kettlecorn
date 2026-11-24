defmodule DuneExample.Allowlist do
  @moduledoc """
  Extends Dune's default policy to restrict clock reads, implicit randomness,
  and process identity. Allows host calls and random draws from explicit
  generator state.
  """
  @behaviour Dune.Allowlist

  @denied %{
    Kernel => [:self, :make_ref],
    Process => :all,
    Date => [:utc_today],
    DateTime => [:utc_now, :now, :now!],
    NaiveDateTime => [:utc_now, :local_now],
    Time => [:utc_now],
    # These use :rand's per-process state, which is seeded randomly.
    Enum => [:random, :take_random, :shuffle],
    :erlang => [
      :date,
      :localtime,
      :localtime_to_universaltime,
      :make_ref,
      :monotonic_time,
      :ref_to_list,
      :system_time,
      :time,
      :time_offset,
      :timestamp,
      :unique_integer,
      :universaltime,
      :universaltime_to_localtime
    ]
  }

  # Dune parses `Kettlecorn.Host` into existing atoms, one per segment.
  # Literal atoms are created when this module loads.
  @doc false
  def alias_segments, do: [:Kettlecorn, :Host]

  @impl true
  def fun_status(Kettlecorn.Host, :call, arity) when arity in 1..3, do: :allowed

  # seed_s/1 chooses a seed implicitly. Require the caller to supply it.
  def fun_status(:rand, fun, arity),
    do: if({fun, arity} in [seed_s: 2, uniform_s: 2], do: :allowed, else: :restricted)

  def fun_status(module, fun, arity) do
    case Map.get(@denied, module, []) do
      :all ->
        :restricted

      funs ->
        if fun in funs,
          do: :restricted,
          else: Dune.Allowlist.Default.fun_status(module, fun, arity)
    end
  end
end
