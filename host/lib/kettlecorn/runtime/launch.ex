defmodule Kettlecorn.Runtime.Launch do
  @moduledoc false

  @doc false
  # `launch/<name>-args` hold one argument per line, `launch/env` NAME=value
  # per line, `launch/module` and `launch/http-module` a file name each.
  @spec validate(Path.t()) :: :ok | {:error, String.t()}
  def validate(dir) do
    with {:ok, _emulator} <- lines(dir, "emulator-args"),
         {:ok, _init} <- lines(dir, "init-args"),
         {:ok, env} <- lines(dir, "env"),
         :ok <- env(dir, env),
         {:ok, _module} <- emulator(dir, "module"),
         {:ok, _http_module} <- emulator(dir, "http-module") do
      :ok
    end
  end

  defp env(dir, lines) do
    if Enum.all?(lines, &String.contains?(&1, "=")),
      do: :ok,
      else: {:error, "#{dir}/launch/env has a line that isn't NAME=value"}
  end

  defp emulator(dir, name) do
    case lines(dir, name) do
      {:ok, [module]} -> in_runtime(dir, module)
      {:ok, _lines} -> {:error, "#{dir}/launch/#{name} doesn't name one emulator"}
      {:error, _} = error -> error
    end
  end

  defp in_runtime(dir, module) do
    if Path.basename(module) == module and File.regular?(Path.join(dir, module)),
      do: {:ok, module},
      else: {:error, "#{dir} is not a complete runtime (no #{module})"}
  end

  defp lines(dir, name) do
    path = Path.join([dir, "launch", name])

    case File.read(path) do
      {:ok, text} -> {:ok, String.split(text, "\n", trim: true)}
      {:error, _} -> {:error, "#{dir} is not a complete runtime (no #{path})"}
    end
  end
end
