defmodule Kettlecorn.Evaluator.Elixir do
  @moduledoc false

  def eval(code, binding) do
    {value, _binding} = Code.eval_string(code, binding, file: "nofile")
    {:ok, value}
  end

  def inspected(value), do: inspect(value, pretty: true)

  def message(kind, reason, stacktrace) do
    own = [__MODULE__, Kettlecorn.Evaluator]
    Exception.format(kind, reason, Enum.reject(stacktrace, &(elem(&1, 0) in own)))
  end
end
