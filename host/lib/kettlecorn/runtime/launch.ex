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
    with {:ok, text} <- read(dir, name) do
      module = String.trim(text)

      if module == "" or String.contains?(module, ["\r", "\n"]),
        do: {:error, "#{dir}/launch/#{name} doesn't name one emulator"},
        else: in_runtime(dir, module)
    end
  end

  defp in_runtime(dir, module) do
    if Path.basename(module) == module and File.regular?(Path.join(dir, module)),
      do: {:ok, module},
      else: {:error, "#{dir} is not a complete runtime (no #{module})"}
  end

  defp lines(dir, name) do
    with {:ok, text} <- read(dir, name) do
      {:ok, :binary.split(text, ["\r\n", "\n"], [:global, :trim_all])}
    end
  end

  defp read(dir, name) do
    path = Path.join([dir, "launch", name])

    with {:ok, text} <- File.read(path), true <- String.valid?(text) do
      {:ok, text}
    else
      false -> {:error, "#{path} must contain UTF-8 text"}
      {:error, _} -> {:error, "#{dir} is not a complete runtime (no #{path})"}
    end
  end
end
