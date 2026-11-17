defmodule Kettlecorn.Dir do
  @moduledoc false

  # Dereference build symlinks so bundles do not depend on the original build tree.
  def copy_tree!(src, dst) do
    File.mkdir_p!(dst)

    case System.cmd("cp", ["-RL", src <> "/.", dst], stderr_to_stdout: true) do
      {_, 0} -> :ok
      {out, _} -> raise File.CopyError, reason: :eio, source: src, destination: dst, action: out
    end
  end

  def resolve(dir), do: resolve(Path.expand(dir), 40)

  defp resolve(dir, 0), do: {:error, "too many symbolic links resolving #{dir}"}

  defp resolve(dir, remaining) do
    case File.read_link(dir) do
      {:ok, target} -> resolve(Path.expand(target, Path.dirname(dir)), remaining - 1)
      {:error, :einval} -> {:ok, dir}
      {:error, :enoent} -> {:ok, dir}
      {:error, reason} -> {:error, "cannot resolve #{dir}: #{:file.format_error(reason)}"}
    end
  end

  # Published generations remain available to readers holding resolved paths.
  def replace(dir, build) do
    dir = Path.expand(dir)
    File.mkdir_p!(Path.dirname(dir))
    generations = dir <> ".versions"
    File.mkdir_p!(generations)
    staging = Path.join(generations, unique("tmp"))
    File.mkdir!(staging)

    try do
      with {:ok, built} <- build.(staging), do: publish(built, dir, generations)
    after
      File.rm_rf!(staging)
    end
  end

  defp publish(built, dir, generations) do
    generation = Path.join(generations, unique("generation"))
    pointer = Path.join(Path.dirname(dir), unique(".kettlecorn-link"))
    target = Path.relative_to(generation, Path.dirname(dir))

    with :ok <- File.rename(built, generation) do
      try do
        with :ok <- File.ln_s(target, pointer),
             :ok <- File.rename(pointer, dir) do
          :ok
        else
          {:error, reason} ->
            File.rm_rf!(generation)

            {:error,
             "cannot publish #{dir}: #{:file.format_error(reason)}; " <>
               "an existing directory must be moved aside before the first publication"}
        end
      after
        File.rm(pointer)
      end
    end
  end

  defp unique(prefix),
    do: prefix <> "-" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
end
