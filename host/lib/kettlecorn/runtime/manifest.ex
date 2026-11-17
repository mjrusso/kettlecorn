defmodule Kettlecorn.Runtime.Manifest do
  @moduledoc """
  A runtime's `manifest.json`, as `Kettlecorn.Runtime.load/1` reads it for
  a runtime with this library's protocol version.

    * `kettlecorn` - the runtime's version.
    * `protocol` - the protocol version (`Kettlecorn.Runtime.protocol_version/0`).
    * `platform` - the native launcher's system: `x86_64-linux`,
      `aarch64-linux` or `aarch64-darwin`.
    * `otp`, `elixir` - the guest's OTP and Elixir versions.
    * `imports` - the WASI interfaces each emulator imports, by file name
      (`"beam.wasm"`, `"beam-http.wasm"`): what a host must provide.
    * `tested_wasmtime` - the Wasmtime version embedded in the launcher
      (`"tested_with": {"wasmtime": ...}` in the file; the runtime also
      writes it to `launch/engine-version` for debugging with the CLI).
  """
  @enforce_keys [:kettlecorn, :protocol, :otp, :elixir, :imports, :tested_wasmtime, :platform]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          kettlecorn: String.t(),
          protocol: pos_integer(),
          otp: String.t(),
          elixir: String.t(),
          imports: %{String.t() => [String.t()]},
          tested_wasmtime: String.t(),
          platform: String.t()
        }

  @doc false
  @spec parse(map()) :: {:ok, t()} | :error
  def parse(%{
        "kettlecorn" => kettlecorn,
        "protocol" => protocol,
        "otp" => otp,
        "elixir" => elixir,
        "imports" => imports,
        "platform" => platform,
        "tested_with" => %{"wasmtime" => wasmtime}
      })
      when is_binary(kettlecorn) and is_integer(protocol) and is_binary(otp) and is_binary(elixir) and
             is_map(imports) and is_binary(wasmtime) and is_binary(platform) do
    {:ok,
     %__MODULE__{
       kettlecorn: kettlecorn,
       protocol: protocol,
       otp: otp,
       elixir: elixir,
       imports: imports,
       platform: platform,
       tested_wasmtime: wasmtime
     }}
  end

  def parse(_other), do: :error
end
