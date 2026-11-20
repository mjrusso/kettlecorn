defmodule Kettlecorn.Dir do
  @moduledoc false

  require Logger

  # Dereference build symlinks so bundles do not depend on the original build tree.
  def copy_tree!(src, dst) do
    File.mkdir_p!(dst)

    case System.cmd("cp", ["-RL", src <> "/.", dst], stderr_to_stdout: true) do
      {_, 0} -> :ok
      {out, _} -> raise File.CopyError, reason: :eio, source: src, destination: dst, action: out
    end
  end

  def resolve(dir) do
    [root | components] = dir |> Path.expand() |> Path.split()
    resolve(root, components, 40)
  end

  defp resolve(dir, [], _remaining), do: {:ok, dir}

  defp resolve(dir, [component | rest], remaining) when component in [".", ".."] do
    case File.stat(dir) do
      {:ok, %{type: :directory}} ->
        resolve(if(component == "..", do: Path.dirname(dir), else: dir), rest, remaining)

      {:ok, _} ->
        filesystem_error("resolve", dir, :enotdir)

      {:error, reason} ->
        filesystem_error("resolve", dir, reason)
    end
  end

  defp resolve(dir, [component | rest], remaining) do
    path = Path.join(dir, component)

    case File.read_link(path) do
      {:ok, _target} when remaining == 0 ->
        {:error, "too many symbolic links resolving #{path}"}

      {:ok, target} ->
        case Path.split(target) do
          ["/" | components] -> resolve("/", components ++ rest, remaining - 1)
          components -> resolve(dir, components ++ rest, remaining - 1)
        end

      {:error, :einval} ->
        resolve(path, rest, remaining)

      {:error, :enoent} ->
        {:ok, Path.join([path | rest])}

      {:error, reason} ->
        filesystem_error("resolve", path, reason)
    end
  end

  # The caller owns the destination and authorizes replacing any non-directory entry there.
  def replace(dir, build) do
    case stage(dir, build, &replace_link/2) do
      {:error, reason} when is_atom(reason) ->
        {:error, "cannot replace #{dir}: #{:file.format_error(reason)}"}

      result ->
        result
    end
  end

  def create(dir, build) do
    stage(dir, build, fn target, destination ->
      case File.ln_s(target, destination) do
        {:error, :eexist} -> :occupied
        result -> filesystem(result, "create publication link", destination)
      end
    end)
  end

  defp stage(dir, build, link) do
    dir = Path.expand(dir)
    generations = dir <> ".versions"
    staging = Path.join(generations, unique("tmp"))

    with :ok <- filesystem(File.mkdir_p(generations), "create generation directory", generations),
         :ok <- filesystem(File.mkdir(staging), "create staging directory", staging) do
      try do
        with {:ok, built} <- build.(staging), do: publish(built, dir, generations, link)
      after
        cleanup(staging)
      end
    end
  end

  defp publish(built, dir, generations, link) do
    generation = Path.join(generations, unique("generation"))
    target = Path.relative_to(generation, Path.dirname(dir))

    with :ok <- filesystem(File.rename(built, generation), "move staged build to", generation) do
      case link.(target, dir) do
        :ok ->
          :ok

        result ->
          cleanup(generation)
          result
      end
    end
  end

  defp replace_link(target, dir) do
    pointer = Path.join(Path.dirname(dir), unique(".kettlecorn-link"))

    with :ok <- filesystem(File.ln_s(target, pointer), "create publication link", pointer) do
      case filesystem(File.rename(pointer, dir), "replace publication link", dir) do
        :ok ->
          :ok

        error ->
          cleanup_link(pointer)
          error
      end
    end
  end

  defp filesystem(:ok, _action, _path), do: :ok
  defp filesystem({:error, reason}, action, path), do: filesystem_error(action, path, reason)

  defp filesystem_error(action, path, reason),
    do: {:error, "cannot #{action} #{path}: #{:file.format_error(reason)}"}

  defp cleanup(path) do
    case File.rm_rf(path) do
      {:ok, _} ->
        :ok

      {:error, reason, failed_path} ->
        warn_cleanup(failed_path, reason)
    end
  end

  defp cleanup_link(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> warn_cleanup(path, reason)
    end
  end

  defp warn_cleanup(path, reason),
    do: Logger.warning("cannot clean up #{path}: #{:file.format_error(reason)}")

  defp unique(prefix),
    do: prefix <> "-" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
end
