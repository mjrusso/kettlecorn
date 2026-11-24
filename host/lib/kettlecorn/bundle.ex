defmodule Kettlecorn.Bundle do
  @moduledoc false

  alias Kettlecorn.{Dir, Protocol, Runtime}

  def compiler do
    %{
      "protocol" => Protocol.version(),
      "otp" => System.otp_release(),
      "elixir" => System.version()
    }
  end

  defp compatible?(fields, manifest) do
    fields == %{
      "protocol" => manifest.protocol,
      "otp" => manifest.otp |> String.split(".") |> hd(),
      "elixir" => manifest.elixir
    }
  end

  def runtime(nil), do: {:ok, nil}

  def runtime(%Runtime{} = runtime) do
    if compatible?(compiler(), runtime.manifest),
      do: {:ok, runtime},
      else: {:error, "the compiler must match the runtime's OTP major and exact Elixir version"}
  end

  def runtime(dir) do
    with {:ok, runtime} <- Runtime.load(dir), do: runtime(runtime)
  end

  def load(dir, manifest) do
    with {:ok, dir} <- Dir.resolve(dir),
         {:ok, json} <- File.read(Path.join(dir, "kettlecorn.json")),
         {:ok, fields} <- JSON.decode(json),
         true <- compatible?(fields, manifest),
         true <- File.regular?(Path.join(dir, "app")) do
      {:ok, dir}
    else
      _ -> {:error, "#{dir} is not a compatible cooked application; cook it with this runtime"}
    end
  end
end
