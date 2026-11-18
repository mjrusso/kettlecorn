defmodule Kettlecorn.Runtime do
  @moduledoc """
  Finds a platform runtime containing the native launcher, WebAssembly
  emulators and guest file system.

  `load!/1` checks the host platform and protocol version, then loads the
  manifest and `launch/` files. Install the matching runtime with
  `mix kettlecorn.install`; Python and the Wasmtime CLI are not required.

  `dir/1` checks the `:runtime` option, `$KETTLECORN_RUNTIME`,
  `config :kettlecorn, :runtime`, then `installed_dir/0`.
  With Nix, `nix build .#runtime` builds the runtime.

  The manifest records `kettlecorn`, `protocol`, `platform`, `otp`, `elixir`,
  component `imports`, and `tested_with.wasmtime`. The bundled launcher embeds
  that Wasmtime version. `launch/` defines the guest's arguments and environment.
  """

  alias Kettlecorn.Runtime.{Launch, Manifest}

  @enforce_keys [:dir, :manifest]
  defstruct @enforce_keys

  @type t :: %__MODULE__{dir: Path.t(), manifest: Manifest.t()}

  @version Mix.Project.config()[:version]

  @doc "The library's version, which is the version of the runtime it installs."
  @spec version() :: String.t()
  def version, do: @version

  @doc "The protocol version required by the library."
  @spec protocol_version() :: pos_integer()
  def protocol_version, do: Kettlecorn.Protocol.version()

  @doc """
  Where `Kettlecorn.Install.runtime/1` puts this version's runtime,
  under the user cache directory.
  """
  @spec installed_dir() :: Path.t()
  def installed_dir,
    do: :user_cache |> :filename.basedir(~c"kettlecorn/runtime-#{@version}") |> to_string()

  @doc """
  The runtime directory to use (see the module docs), or `nil` when there is
  none.
  """
  @spec dir(keyword()) :: Path.t() | nil
  def dir(opts \\ []) do
    configured =
      opts[:runtime] || env("KETTLECORN_RUNTIME") ||
        Application.get_env(:kettlecorn, :runtime)

    cond do
      configured -> Path.expand(configured)
      File.regular?(Path.join(installed_dir(), "manifest.json")) -> installed_dir()
      true -> nil
    end
  end

  @doc "Finds and loads a runtime using the discovery order of `dir/1`."
  @spec find(keyword()) :: {:ok, t()} | {:error, String.t()}
  def find(opts) do
    case dir(opts) do
      nil ->
        {:error,
         "No Kettlecorn runtime found: run `mix kettlecorn.install`, " <>
           "or set :runtime / KETTLECORN_RUNTIME"}

      dir ->
        load(dir)
    end
  end

  @doc "The bundled native launcher for this runtime."
  @spec executable(t()) :: Path.t()
  def executable(%__MODULE__{dir: dir}), do: Path.join([dir, "bin", "kettlecorn-launch"])

  @doc "The bundled script CLI for this runtime."
  @spec cli(t()) :: Path.t()
  def cli(%__MODULE__{dir: dir}), do: Path.join([dir, "bin", "kettlecorn-run"])

  @doc false
  def populate_root!(runtime, root, options) do
    args = ["--prepare-root", "--runtime", runtime.dir, "--root", root | options]

    case System.cmd(executable(runtime), args, stderr_to_stdout: true) do
      {_output, 0} ->
        :ok

      {output, _status} ->
        raise File.CopyError,
          reason: :eio,
          source: runtime.dir,
          destination: root,
          action: String.trim(output)
    end
  end

  @doc false
  # An empty variable counts as unset, as in bin/kettlecorn-run.
  @spec env(String.t()) :: String.t() | nil
  def env(name) do
    case System.get_env(name) do
      "" -> nil
      value -> value
    end
  end

  @doc """
  Loads one generation of the runtime in `dir`, resolving its publication link.
  Requires its manifest, executable launcher and CLI, `launch/` files, emulators and
  `root/`. Checks the host platform and the library's protocol version.
  Both executables are required even when using only the host API.
  Raises if the runtime is incomplete or incompatible.
  """
  @spec load!(Path.t()) :: t()
  def load!(dir) do
    case load(dir) do
      {:ok, runtime} -> runtime
      {:error, message} -> raise ArgumentError, message
    end
  end

  @doc "Like `load!/1`, but returns `{:ok, runtime}` or `{:error, message}`."
  @spec load(Path.t()) :: {:ok, t()} | {:error, String.t()}
  def load(dir) do
    with {:ok, dir} <- Kettlecorn.Dir.resolve(dir),
         {:ok, manifest} <- manifest(dir),
         :ok <- platform(manifest),
         :ok <- executable_file(dir, "kettlecorn-launch"),
         :ok <- executable_file(dir, "kettlecorn-run"),
         :ok <- Launch.validate(dir) do
      if File.dir?(Path.join(dir, "root")),
        do: {:ok, %__MODULE__{dir: dir, manifest: manifest}},
        else: {:error, "#{dir} is not a complete runtime (no root/)"}
    end
  end

  defp manifest(dir) do
    path = Path.join(dir, "manifest.json")
    expected = protocol_version()

    # Only "protocol" (and "kettlecorn", for the message) are read before
    # the protocol matches: another version's manifest may differ.
    with {:ok, json} <- File.read(path),
         {:ok, %{"protocol" => ^expected} = fields} <- JSON.decode(json),
         {:ok, manifest} <- Manifest.parse(fields) do
      {:ok, manifest}
    else
      {:error, :enoent} ->
        {:error, "#{dir} is not a Kettlecorn runtime (no manifest.json)"}

      {:ok, %{"protocol" => protocol} = fields} ->
        {:error,
         "the runtime in #{dir} (Kettlecorn #{fields["kettlecorn"]}) speaks protocol " <>
           "#{protocol}, this library (#{@version}) speaks #{expected}: " <>
           "install the matching runtime with `mix kettlecorn.install`"}

      _invalid ->
        {:error, "#{path} is not a valid runtime manifest"}
    end
  end

  defp platform(manifest) do
    case Kettlecorn.Platform.current() do
      {:ok, platform} when platform == manifest.platform -> :ok
      {:ok, platform} -> {:error, "runtime is for #{manifest.platform}, this host is #{platform}"}
      {:error, _} = error -> error
    end
  end

  defp executable_file(dir, name) do
    path = Path.join([dir, "bin", name])

    case File.stat(path) do
      {:ok, %{type: :regular, mode: mode}} when Bitwise.band(mode, 0o111) != 0 -> :ok
      _ -> {:error, "#{dir} is not a complete runtime (no executable bin/#{name})"}
    end
  end
end
