defmodule Kettlecorn.Platform do
  @moduledoc false

  def current, do: target(to_string(:erlang.system_info(:system_architecture)), :os.type())

  def target(arch, os) do
    cpu =
      cond do
        String.starts_with?(arch, ["x86_64", "amd64"]) -> "x86_64"
        String.starts_with?(arch, ["aarch64", "arm64"]) -> "aarch64"
        true -> nil
      end

    case {cpu, os} do
      {cpu, {:unix, :linux}} when cpu != nil -> {:ok, "#{cpu}-linux"}
      {"aarch64", {:unix, :darwin}} -> {:ok, "aarch64-darwin"}
      _ -> {:error, "no Kettlecorn runtime for #{arch} (#{inspect(os)})"}
    end
  end
end
