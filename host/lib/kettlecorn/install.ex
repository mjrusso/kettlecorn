defmodule Kettlecorn.Install do
  @moduledoc """
  Installs the native runtime for this platform from a GitHub release.

  `runtime/1` downloads `kettlecorn-runtime-<version>-<system>.tar.gz`, or
  reads it from `:archive`, and verifies its SHA-256 against the package's
  `priv/checksums.txt`. Configure `:release_base_url` for a mirror with the
  same release layout. The archive includes the launcher; no separate
  Wasmtime installation is needed.
  """

  require Logger

  alias Kettlecorn.{Dir, Runtime}

  @release_base "https://github.com/mjrusso/kettlecorn/releases/download"

  @doc "Release archive name for this platform."
  def archive_name do
    with {:ok, platform} <- Kettlecorn.Platform.current(),
         do: {:ok, "kettlecorn-runtime-#{Runtime.version()}-#{platform}.tar.gz"}
  end

  defp url(name) do
    base = Application.get_env(:kettlecorn, :release_base_url, @release_base)
    "#{base}/v#{Runtime.version()}/#{name}"
  end

  @doc """
  Installs the runtime for this package version. Set `:dir` to change the
  destination from `Kettlecorn.Runtime.installed_dir/0`. Set `:archive` to
  install from a local archive for this version and platform.

  Reuses a compatible installation unless `force: true`. Forced reinstalls
  atomically replace the destination and keep previous generations in
  `<dir>.versions` for existing readers.
  Move an invalid cache symlink aside to repair it with an ordinary install.
  Use `force: true` only at a destination you own. It authorizes overwriting
  any non-directory entry at that path, including a regular file. Move an
  existing ordinary directory aside before installing to that path.
  Returns `{:ok, dir}` or `{:error, message}`.
  """
  @spec runtime(keyword()) :: {:ok, Path.t()} | {:error, String.t()}
  def runtime(opts \\ []), do: install_runtime(opts, &expected_checksum/1)

  if Mix.env() == :test do
    @doc false
    def runtime(opts, checksum), do: install_runtime(opts, checksum)
  end

  defp install_runtime(opts, checksum) do
    dir = opts[:dir] || Runtime.installed_dir()
    source = if path = opts[:archive], do: {:file, path}, else: :release

    if opts[:force] == true,
      do: install(dir, true, source, checksum),
      else: install_if_missing(dir, source, checksum)
  end

  defp install_if_missing(dir, source, checksum) do
    case Runtime.lookup_cache(dir) do
      :missing -> install(dir, false, source, checksum)
      result -> with :ok <- reuse(result, dir), do: {:ok, dir}
    end
  end

  defp reuse({:ok, _}, _dir), do: :ok

  defp reuse({:error, reason}, dir),
    do: {:error, "#{reason}. Move #{dir} aside before installing."}

  defp reuse(:missing, dir), do: {:error, "#{dir} disappeared during installation"}

  defp install(dir, force, source, checksum) do
    with {:ok, name} <- archive_name(),
         {:ok, expected} <- checksum.(name),
         {:ok, archive} <- read(source, name),
         :ok <- verify(archive, name, expected),
         :ok <- unpack_runtime(archive, dir, force) do
      {:ok, dir}
    end
  end

  defp unpack_runtime(archive, dir, force) do
    build = fn staging ->
      with :ok <- extract(archive, staging),
           {:ok, [top]} <- File.ls(staging),
           {:ok, _runtime} <- Runtime.load_release(Path.join(staging, top)) do
        {:ok, Path.join(staging, top)}
      else
        {:ok, _entries} -> {:error, "runtime archive doesn't hold one runtime directory"}
        {:error, message} -> {:error, message}
      end
    end

    if force, do: Dir.replace(dir, build), else: publish(dir, build)
  end

  defp publish(dir, build) do
    case Dir.create(dir, build) do
      :ok ->
        :ok

      :occupied ->
        dir |> Runtime.lookup_cache() |> reuse(dir)

      {:error, reason} when is_atom(reason) ->
        {:error, "cannot publish #{dir}: #{:file.format_error(reason)}"}

      {:error, _} = error ->
        error
    end
  end

  defp extract(archive, staging) do
    case :erl_tar.extract({:binary, archive}, [:compressed, cwd: String.to_charlist(staging)]) do
      :ok -> :ok
      {:error, reason} -> {:error, "unpacking runtime archive: #{inspect(reason)}"}
    end
  end

  defp read(:release, name), do: download(url(name))

  defp read({:file, path}, _name) do
    case File.read(path) do
      {:ok, archive} -> {:ok, archive}
      {:error, reason} -> {:error, "reading #{path}: #{:file.format_error(reason)}"}
    end
  end

  # priv/checksums.txt: `sha256sum` lines, "<sha256>  <file name>".
  defp expected_checksum(name) do
    found =
      :kettlecorn
      |> :code.priv_dir()
      |> Path.join("checksums.txt")
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.find_value(fn line ->
        case String.split(line) do
          [sha256, ^name] -> sha256
          _ -> nil
        end
      end)

    if found,
      do: {:ok, found},
      else:
        {:error,
         "no checksum for #{name} in priv/checksums.txt: this version of the library doesn't " <>
           "install it (for the runtime: build one with `nix build .#runtime` and set KETTLECORN_RUNTIME)"}
  end

  defp download(url) do
    {:ok, _} = Application.ensure_all_started([:inets, :ssl])
    Logger.info("kettlecorn: downloading #{url}")

    ssl = [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]

    http = [ssl: ssl, autoredirect: true, connect_timeout: 30_000, timeout: 600_000]

    case :httpc.request(:get, {String.to_charlist(url), []}, http, body_format: :binary) do
      {:ok, {{_, 200, _}, _headers, body}} -> {:ok, body}
      {:ok, {{_, status, _}, _, _}} -> {:error, "downloading #{url}: HTTP #{status}"}
      {:error, reason} -> {:error, "downloading #{url}: #{inspect(reason)}"}
    end
  end

  defp verify(archive, name, expected) do
    actual = :sha256 |> :crypto.hash(archive) |> Base.encode16(case: :lower)

    if actual == expected,
      do: :ok,
      else: {:error, "#{name}: SHA-256 #{actual}, expected #{expected}"}
  end
end
