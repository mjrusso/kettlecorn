defmodule Kettlecorn.Host do
  @moduledoc """
  Sends messages and requests from the guest to its host.

    * `send/1` sends a term to the host. It arrives in the VM's `:owner` as
      `{:kettlecorn, vm, {:message, term}}`.
    * `call/3` asks the host to do something and waits for the answer: a
      *host call*. The host decides what `name` means, and answers with
      `Kettlecorn.reply/3`.

  The host sends messages to guest processes with `Kettlecorn.send/4`. They
  arrive as `{:wasm, payload}`.

  Under `kettlecorn-run` there is no host program: `send/1` is a no-op and
  `call/3` times out.
  """

  @compile {:no_warn_undefined, :wasm}

  @doc "Sends `term` to the host."
  @spec send(term()) :: :ok
  def send(term), do: :wasm.send(term)

  @doc """
  Makes a host call: `{:ok, value}`, `{:error, reason}` from the host, or
  `{:error, :timeout}` (option `:timeout`, default 5000 ms).
  """
  @spec call(String.t(), map(), timeout: timeout()) :: {:ok, term()} | {:error, term()}
  def call(name, args \\ %{}, opts \\ []) when is_binary(name) and is_map(args) do
    :wasm.host_call(name, args, opts)
  end
end
