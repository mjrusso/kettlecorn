defmodule Kettlecorn.Sandbox do
  alias Kettlecorn.Options

  @options_schema NimbleOptions.new!(
                    max_memory: [
                      type: :pos_integer,
                      default: 512 * 1024 * 1024,
                      doc:
                        "Linear memory cap in bytes. Allocations that exceed it fail and can terminate the VM."
                    ],
                    max_lifetime: [
                      type: {:or, [:pos_integer, {:in, [:infinity]}]},
                      default: :infinity,
                      doc: """
                      Wall-clock limit for the whole VM in milliseconds, enforced by Wasmtime and, as a
                      backstop, by `Kettlecorn.VM`.
                      """
                    ],
                    max_fuel: [
                      type: {:or, [:pos_integer, {:in, [:infinity]}]},
                      default: :infinity,
                      doc: """
                      CPU budget for the whole VM, including boot, in Wasmtime fuel units (roughly Wasm
                      instructions). Exhaustion stops the guest with `{:vm_down, :out_of_fuel}`.
                      """
                    ],
                    network: [
                      type: :boolean,
                      default: false,
                      doc: """
                      Allows TCP/UDP sockets and DNS. **This allows any destination**, including internal
                      addresses; Kettlecorn has no host or port allowlist.
                      """
                    ],
                    cacerts: [
                      type: {:or, [{:in, [:host]}, :string, {:list, :string}]},
                      type_doc: "`:host`, a PEM file path, or a list of DER certificates",
                      default: :host,
                      doc: """
                      The CA certificates the guest trusts with `network: true`: `:public_key.cacerts_get/0`
                      in the guest returns them, and Req uses them. `:host` passes the host's, and a PEM file
                      or a list of DER certificates replaces them. With `[]`, or `:host` without a host trust
                      store, `:public_key.cacerts_get/0` and Req HTTPS requests without their own `:cacerts`
                      raise in the guest. With `http: true`, Wasmtime uses its compiled Mozilla root CA list;
                      this option does not change those roots.
                      """
                    ],
                    http: [
                      type: :boolean,
                      default: false,
                      doc: """
                      Allows `Kettlecorn.HTTP` requests through `wasi:http` with `beam-http.wasm`.
                      Req uses `Kettlecorn.HTTP.ReqAdapter`. Allows any destination.
                      """
                    ],
                    schedulers: [
                      type: :pos_integer,
                      default: 1,
                      doc: """
                      BEAM schedulers. They run as cooperative threads on one OS thread, so more schedulers
                      add no parallelism.
                      """
                    ],
                    runtime: [
                      type: {:or, [:string, nil]},
                      default: nil,
                      doc: """
                      Runtime directory. When nil, uses `$KETTLECORN_RUNTIME`, `config :kettlecorn,
                      :runtime`, then the runtime installed by `mix kettlecorn.install`. Its manifest must
                      declare this library's protocol version. See `Kettlecorn.Runtime`.
                      """
                    ],
                    app: [
                      type: {:or, [:string, nil]},
                      default: nil,
                      doc: """
                      Cooked application directory (see `Kettlecorn.Cook`). Its applications take
                      precedence over runtime copies. The guest loads its `sys.config` and starts its
                      entrypoint before reporting that it has booted.
                      """
                    ],
                    code_paths: [
                      type: {:list, :string},
                      default: [],
                      doc: """
                      Extra host directories with `.beam` files, copied into the guest and added to its
                      code path.
                      """
                    ],
                    instances_dir: [
                      type: {:or, [:string, nil]},
                      default: nil,
                      doc: """
                      Parent directory for each VM's private directory (mode 0700), containing the guest
                      root and the launcher's stderr. When nil, uses the system temporary directory.
                      """
                    ],
                    apps: [
                      type: {:list, {:custom, Options, :application_name, []}},
                      type_doc: "list of application names (atoms or non-empty strings)",
                      default: [],
                      doc: """
                      Extra applications to start at boot, available in the runtime, `:code_paths` or the
                      cooked app.
                      """
                    ],
                    preload: [
                      type: {:in, [false, true, :strict]},
                      default: false,
                      doc: """
                      With `true` or `:strict`, load modules on the boot-time code path in name
                      order, skipping those already loaded. A preload failure aborts boot. Later
                      on-demand loads produce `{:late_load, "Elixir.Mod"}` owner events. `:strict`
                      also stops the VM on such a load. See [preloading modules](sandbox.html#preloading-modules).
                      """
                    ],
                    env: [
                      type: {:custom, Options, :environment, []},
                      type_doc: "map or list of environment names to string values",
                      default: %{},
                      doc: """
                      Extra guest environment variables. Names must be non-empty and contain no `=`. Names
                      and values must contain no line breaks or NULs.
                      """
                    ],
                    compile_cache: [
                      type: :boolean,
                      default: true,
                      doc: "Cache compiled components in the private per-user cache."
                    ],
                    cache_dir: [
                      type: {:or, [:string, nil]},
                      default: nil,
                      doc:
                        "Override the private component cache directory; unusable caches fall back to compilation."
                    ],
                    emulator_flags: [
                      type: {:list, :string},
                      default: [],
                      doc: """
                      Extra emulator flags as `erl` passes them to `beam`: with a dash instead of `+`, e.g.
                      `[\"-hms\", \"1000\"]` for `+hms 1000`.
                      """
                    ]
                  )

  @moduledoc """
  Validated VM options: limits, grants, guest code and runtime.
  `Kettlecorn.Sandbox.Instance` creates the VM's private directory and its
  launcher command line.

  The guest has access to:

    * a **private copy** of the runtime root (OTP + Elixir `.beam` files and
      any `:code_paths`) mounted at `/`, created when the VM starts and deleted
      after confirmed launcher shutdown. A guest can't affect the runtime or
      other VMs through the file system;
    * the runtime's `launch/env` variables, with `:env` overrides; host
      environment variables are not inherited,
    * a fixed host name, `localhost` (never the host's),
    * stdin/stdout for the frame protocol.

  Guest writes are not size-limited by Wasmtime: put
  `:instances_dir` on a size-limited file system (e.g. a tmpfs) if guests
  must not be able to fill your disk.

  By default it has no network access, cannot spawn OS processes and cannot
  load native code.

  ## Options

  #{NimbleOptions.docs(@options_schema)}
  """

  @enforce_keys Keyword.keys(@options_schema.schema)
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          runtime: Kettlecorn.Runtime.t(),
          app: Path.t() | nil,
          instances_dir: Path.t() | nil,
          max_memory: pos_integer(),
          max_lifetime: pos_integer() | :infinity,
          max_fuel: pos_integer() | :infinity,
          network: boolean(),
          http: boolean(),
          cacerts: [:public_key.der_encoded()],
          schedulers: pos_integer(),
          code_paths: [Path.t()],
          apps: [atom() | String.t()],
          preload: boolean() | :strict,
          env: %{String.t() => String.t()},
          compile_cache: boolean(),
          cache_dir: Path.t() | nil,
          emulator_flags: [String.t()]
        }

  @doc """
  Builds the sandbox for `opts` (see the module doc). Raises `ArgumentError`
  for an unknown or invalid option, or a missing or incompatible runtime.
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    opts = Options.validate!(opts, @options_schema)

    runtime =
      case Kettlecorn.Runtime.find(opts) do
        {:ok, runtime} -> runtime
        {:error, message} -> raise ArgumentError, message
      end

    fields = Map.new(opts)

    struct!(
      __MODULE__,
      %{
        fields
        | runtime: runtime,
          app: cooked_app(opts[:app], runtime.manifest),
          cacerts: if(opts[:network], do: cacerts(opts[:cacerts]), else: [])
      }
    )
  end

  defp cacerts(:host) do
    for {:cert, der, _decoded} <- :public_key.cacerts_get(), do: der
  rescue
    _ -> []
  end

  defp cacerts(path) when is_binary(path) do
    pem =
      case File.read(path) do
        {:ok, pem} -> pem
        {:error, reason} -> raise ArgumentError, ":cacerts: can't read #{path}: #{reason}"
      end

    case for({:Certificate, der, :not_encrypted} <- :public_key.pem_decode(pem), do: der) do
      [] -> raise ArgumentError, ":cacerts: #{path} contains no PEM certificates"
      ders -> ders
    end
  end

  defp cacerts(ders) do
    Enum.each(ders, &validate_der!/1)
    ders
  end

  defp validate_der!(der) do
    :public_key.pkix_decode_cert(der, :plain)
  rescue
    _ ->
      reraise ArgumentError,
              ":cacerts: #{inspect(der, limit: 8)} isn't a DER certificate",
              __STACKTRACE__
  end

  defp cooked_app(nil, _manifest), do: nil

  defp cooked_app(dir, manifest) do
    case Kettlecorn.Bundle.load(dir, manifest) do
      {:ok, dir} -> dir
      {:error, message} -> raise ArgumentError, message
    end
  end
end
