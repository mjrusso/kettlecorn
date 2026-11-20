defmodule Bot do
  def init(%{"center" => center}), do: center

  def frame(%{"pulses" => pulses}, {cx, cy} = center) do
    {turns, marks} =
      Enum.reduce(pulses, {[], []}, fn {id, {x, y} = cell, {dx, dy}}, {turns, marks} ->
        radius = max(abs(x - cx), abs(y - cy))

        if radius in [6, 12, 18] do
          direction = if rem(div(radius, 6), 2) == 0, do: {dy, -dx}, else: {-dy, dx}
          {[{id, direction} | turns], [{cell, 3} | marks]}
        else
          {turns, [{cell, 0} | marks]}
        end
      end)

    {%{"turns" => turns, "marks" => marks}, center}
  end
end
