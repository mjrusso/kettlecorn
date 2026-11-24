defmodule Kettlecorn.ETF.JSON do
  @moduledoc false

  alias Kettlecorn.{Opaque, Pid, Struct}

  def convert(term) do
    {:ok, json(term)}
  catch
    {:json, reason} -> {:error, reason}
  end

  defp json(term) when is_nil(term) or is_boolean(term) or is_number(term), do: term
  defp json(term) when is_atom(term), do: Atom.to_string(term)
  defp json({:unknown_atom, name}) when is_binary(name), do: string(name)
  defp json(term) when is_binary(term), do: string(term)
  defp json(term) when is_bitstring(term), do: throw({:json, {:unsupported, :bitstring}})
  defp json(term) when is_list(term), do: list(term, [])
  defp json(term) when is_tuple(term), do: term |> Tuple.to_list() |> list([])
  defp json(%Pid{}), do: throw({:json, {:unsupported, :pid}})
  defp json(%Opaque{type: type}), do: throw({:json, {:unsupported, type}})

  defp json(%Struct{module: module, fields: fields}),
    do: object([{:__struct__, Atom.to_string(module)} | Map.to_list(fields)])

  defp json(term) when is_map(term), do: object(Map.to_list(term))

  defp string(binary) do
    if String.valid?(binary), do: binary, else: throw({:json, {:unsupported, :invalid_utf8}})
  end

  defp list([], acc), do: Enum.reverse(acc)
  defp list([head | tail], acc), do: list(tail, [json(head) | acc])
  defp list(_tail, _acc), do: throw({:json, {:unsupported, :improper_list}})

  defp object(pairs) do
    Enum.reduce(pairs, %{}, fn {key, value}, acc ->
      key = key(key)

      if is_map_key(acc, key),
        do: throw({:json, {:duplicate_key, key}}),
        else: Map.put(acc, key, json(value))
    end)
  end

  defp key(key) when is_binary(key), do: string(key)
  defp key(key) when is_integer(key), do: Integer.to_string(key)
  defp key({:unknown_atom, name}) when is_binary(name), do: string(name)
  defp key(key) when is_atom(key), do: Atom.to_string(key)
  defp key(_key), do: throw({:json, {:unsupported, :map_key}})
end
