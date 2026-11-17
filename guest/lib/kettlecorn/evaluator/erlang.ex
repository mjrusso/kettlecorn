defmodule Kettlecorn.Evaluator.Erlang do
  @moduledoc false

  # {:ok, value} or {:error, :error, message} for a scan, parse or compile
  # error; raises what the code raises.
  def eval(code, binding) do
    result =
      with {:ok, tokens, end_location} <- :erl_scan.string(String.to_charlist(code), {1, 1}) do
        case split_on_dots(tokens, end_location) do
          [] -> {:error, {end_location, :erl_parse, ~c"no expression"}}
          [[{:-, _}, {:atom, _, :module} | _] | _] = forms -> load_module(forms)
          expressions -> eval_erlang(expressions, bindings(binding))
        end
      end

    erlang_result(result)
  end

  # Bound output even when a value expands through shared subterms.
  def inspected(value),
    do: IO.chardata_to_string(:io_lib.format(~c"~tp", [value], chars_limit: 100_000))

  def message(kind, reason, stacktrace) do
    trim = fn module, _function, _arity ->
      module in [:erl_eval, __MODULE__, Kettlecorn.Evaluator]
    end

    kind
    |> :erl_error.format_exception(reason, stacktrace, %{stack_trim_fun: trim})
    |> IO.chardata_to_string()
  end

  # Forms end with a dot; one after the last form's tokens is optional.
  defp split_on_dots(tokens, end_location) do
    Enum.chunk_while(
      tokens,
      [],
      fn
        {:dot, _} = dot, form -> {:cont, Enum.reverse([dot | form]), []}
        token, form -> {:cont, [token | form]}
      end,
      fn
        [] -> {:cont, []}
        form -> {:cont, Enum.reverse([{:dot, end_location} | form]), []}
      end
    )
  end

  defp bindings(binding) do
    Enum.reduce(binding, :erl_eval.new_bindings(), fn {name, value}, bindings ->
      :erl_eval.add_binding(name, value, bindings)
    end)
  end

  defp eval_erlang([form | rest], bindings) do
    with {:ok, exprs} <- :erl_parse.parse_exprs(form) do
      {:value, value, bindings} = :erl_eval.exprs(exprs, bindings, {:value, &undefined_local/2})
      if rest == [], do: {:ok, value}, else: eval_erlang(rest, bindings)
    end
  end

  # A call to a local function in an expression: no such function exists.
  # The shell raises the same error, which :erl_error formats.
  defp undefined_local(name, args), do: :erlang.error({:shell_undef, name, length(args), []})

  defp load_module(forms) do
    with {:ok, forms} <- parse_forms(forms),
         {:ok, module, beam} <- :compile.noenv_forms(forms, [:return_errors]),
         {:module, module} <- :code.load_binary(module, ~c"nofile", beam) do
      {:ok, {:module, module}}
    end
  end

  defp parse_forms([]), do: {:ok, []}

  defp parse_forms([form | rest]) do
    with {:ok, parsed} <- :erl_parse.parse_form(form),
         {:ok, parsed_rest} <- parse_forms(rest),
         do: {:ok, [parsed | parsed_rest]}
  end

  defp erlang_result({:ok, _value} = ok), do: ok
  defp erlang_result({:error, {_, _, _} = info, _end}), do: syntax_error([info])
  defp erlang_result({:error, {_, _, _} = info}), do: syntax_error([info])

  defp erlang_result({:error, errors, _warnings}),
    do: syntax_error(Enum.flat_map(errors, &elem(&1, 1)))

  defp erlang_result({:error, reason}),
    do: {:error, :error, "cannot load module: #{inspect(reason)}"}

  defp syntax_error(infos) do
    lines =
      for {location, module, description} <- infos do
        "nofile:#{position(location)}: #{module.format_error(description)}"
      end

    {:error, :error, Enum.join(lines, "\n")}
  end

  defp position({line, column}), do: "#{line}:#{column}"
  defp position(line), do: "#{line}"
end
