defmodule Kettlecorn.Events do
  @moduledoc false

  defstruct [:slots, :bytes, sizes: :queue.new()]

  def new(count, bytes), do: %__MODULE__{slots: count, bytes: bytes}

  def push(events, size) do
    if events.slots == 0 or size > events.bytes do
      :full
    else
      {:ok,
       %{
         events
         | sizes: :queue.in(size, events.sizes),
           slots: events.slots - 1,
           bytes: events.bytes - size
       }}
    end
  end

  def acknowledge(events, 0), do: events

  def acknowledge(events, count) do
    case :queue.out(events.sizes) do
      {:empty, _sizes} ->
        events

      {{:value, size}, sizes} ->
        acknowledge(
          %{events | sizes: sizes, slots: events.slots + 1, bytes: events.bytes + size},
          count - 1
        )
    end
  end
end
