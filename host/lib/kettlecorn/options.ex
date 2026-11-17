defmodule Kettlecorn.Options do
  @moduledoc false

  def validate!(opts, schema) do
    case NimbleOptions.validate(opts, schema) do
      {:ok, validated} -> validated
      {:error, error} -> raise ArgumentError, Exception.message(error)
    end
  end

  defguard is_name(name)
           when (is_atom(name) and name not in [nil, true, false]) or
                  (is_binary(name) and name != "")

  def application_name(name) when is_name(name), do: {:ok, name}

  def application_name(_name), do: {:error, "expected an atom or a non-empty string"}

  def environment(env) when (is_map(env) and not is_struct(env)) or is_list(env) do
    if Enum.all?(env, &env_entry?/1),
      do: {:ok, Map.new(env, fn {name, value} -> {to_string(name), value} end)},
      else: {:error, "expected environment names and string values without line breaks or NULs"}
  end

  def environment(_env), do: {:error, "expected a map or a list of environment variables"}

  # The launcher's --env parses each string as NAME=value.
  defp env_entry?({name, value}) when (is_binary(name) or is_atom(name)) and is_binary(value) do
    name = to_string(name)

    name != "" and not String.contains?(name, ["=", "\n", <<0>>]) and
      not String.contains?(value, ["\n", <<0>>])
  end

  defp env_entry?(_entry), do: false
end
