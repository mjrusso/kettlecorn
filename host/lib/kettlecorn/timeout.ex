defmodule Kettlecorn.Timeout do
  @moduledoc false

  @reply_margin 1_000

  def request(timeout), do: %{proxy: timeout, host: later(timeout)}

  def evaluation(timeout) do
    %{
      evaluation: timeout,
      finish: div(@reply_margin, 2),
      proxy: later(timeout),
      host: later(later(timeout))
    }
  end

  defp later(:infinity), do: :infinity
  defp later(timeout), do: timeout + @reply_margin
end
