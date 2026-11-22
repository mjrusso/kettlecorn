defmodule Kettlecorn.Sandbox.Instance do
  @moduledoc """
  One VM's private directory, and the launcher command line that runs the
  VM on it.

  `Kettlecorn.VM` prepares an instance from a `Kettlecorn.Sandbox`,
  runs `command/1`, and calls `cleanup/1` after confirming launcher shutdown.
  If shutdown cannot be confirmed, it retains the directory and logs an error.
  """
  alias Kettlecorn.Sandbox

  @enforce_keys [:sandbox, :dir]
  defstruct @enforce_keys
  @type t :: %__MODULE__{sandbox: Sandbox.t(), dir: Path.t()}

  @doc """
  Creates the VM's private directory: a new directory with an unguessable
  name, accessible only to this OS user, holding the guest's root (`root/`,
  mounted at `/`) and, out of the guest's reach, the launcher's stderr. On
  failure, removes what it created and raises.
  """
  @spec prepare(Sandbox.t()) :: t()
  def prepare(%Sandbox{} = s) do
    base = s.instances_dir || System.tmp_dir!()
    suffix = 12 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    dir = Path.join(base, "kettlecorn-" <> suffix)
    File.mkdir_p!(base)
    # mkdir, not mkdir_p: fails if the name exists.
    File.mkdir!(dir)

    try do
      File.chmod!(dir, 0o700)
      populate!(s, dir)
      %__MODULE__{sandbox: s, dir: dir}
    rescue
      e ->
        File.rm_rf(dir)
        reraise e, __STACKTRACE__
    end
  end

  @doc "The file the launcher's stderr goes to."
  @spec stderr_file(t()) :: Path.t()
  def stderr_file(%__MODULE__{dir: dir}), do: Path.join(dir, "stderr")

  @doc "The file the launcher keeps the VM's fuel and memory use in."
  @spec stats_file(t()) :: Path.t()
  def stats_file(%__MODULE__{dir: dir}), do: Path.join(dir, "stats")

  @doc "Deletes the VM's private directory."
  @spec cleanup(t()) :: :ok
  def cleanup(%__MODULE__{dir: dir}), do: Kettlecorn.Dir.remove_tree(dir)

  defp root(dir), do: Path.join(dir, "root")

  defp populate!(s, dir) do
    certificates = Path.join(dir, "certificates.pem")

    if s.cacerts != [] do
      File.write!(
        certificates,
        :public_key.pem_encode(for der <- s.cacerts, do: {:Certificate, der, :not_encrypted})
      )
    end

    options =
      if(s.app, do: ["--app-dir", s.app], else: []) ++
        if(s.cacerts != [], do: ["--certificates", certificates], else: []) ++
        Enum.flat_map(code_paths(s), fn {source, guest} ->
          ["--copy-dir", Path.expand(source), "/" <> guest]
        end)

    try do
      Kettlecorn.Runtime.populate_root!(s.runtime, root(dir), options)
    after
      File.rm(certificates)
    end
  end

  @doc "The bundled launcher's executable and arguments for this instance."
  @spec command(t()) :: [String.t()]
  def command(%__MODULE__{sandbox: s, dir: dir}) do
    [Kettlecorn.Runtime.executable(s.runtime)] ++ launcher_args(s, dir)
  end

  defp launcher_args(s, dir) do
    timeout =
      if s.max_lifetime == :infinity, do: [], else: ["--lifetime-ms", to_string(s.max_lifetime)]

    fuel = if s.max_fuel == :infinity, do: [], else: ["--fuel", to_string(s.max_fuel)]

    env =
      s.env
      |> Enum.flat_map(fn {k, v} -> ["--env", "#{k}=#{v}"] end)

    Enum.concat([
      [
        "--runtime",
        s.runtime.dir,
        "--root",
        root(dir),
        "--framed",
        "--stderr",
        Path.join(dir, "stderr"),
        "--stats",
        Path.join(dir, "stats"),
        "--max-memory",
        to_string(s.max_memory),
        "--schedulers",
        to_string(s.schedulers)
      ],
      timeout,
      fuel,
      if(s.network, do: ["--network"], else: []),
      if(s.http, do: ["--http"], else: []),
      if(s.compile_cache, do: [], else: ["--no-cache"]),
      if(s.cache_dir, do: ["--cache-dir", Path.expand(s.cache_dir)], else: []),
      env,
      Enum.flat_map(code_paths(s), fn {_, guest} -> ["--code-path", "/" <> guest] end),
      Enum.flat_map(s.apps, fn app -> ["--app", to_string(app)] end),
      preload_args(s.preload),
      Enum.flat_map(s.emulator_flags, fn flag -> ["--emulator-arg", flag] end)
    ])
  end

  defp preload_args(false), do: []
  defp preload_args(true), do: ["--preload", "on"]
  defp preload_args(:strict), do: ["--preload", "strict"]

  defp code_paths(s),
    do: Enum.with_index(s.code_paths, fn source, index -> {source, "code/#{index}"} end)
end
