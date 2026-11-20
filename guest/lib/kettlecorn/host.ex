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

  When the host advertises a frame size limit, `send/1` and `call/3` check a
  conservative estimate of the encoded frame size before sending. This check
  can reject terms whose actual encoding would fit. It also rejects closures
  and native records because the size check cannot traverse their contents.
  Rejected requests return `{:error, :frame_too_large}`.

  Under `kettlecorn-run` there is no host program: `send/1` is a no-op and
  `call/3` times out.
  """

  @compile {:no_warn_undefined, :wasm}

  @doc """
  Sends `term` to the host. Returns `{:error, :frame_too_large}` if the message
  fails the frame size check.
  """
  @spec send(term()) :: :ok | {:error, :frame_too_large}
  def send(term), do: :wasm.send(term)

  @doc """
  Sends a named request to the host and waits for a reply.

  Returns `{:ok, value}` or `{:error, reason}` from the host.
  Set `:timeout` to change how long the guest waits for a reply. It defaults
  to 5,000 ms. If the wait expires, the call returns `{:error, :timeout}`.
  If the request fails the frame size check, it returns
  `{:error, :frame_too_large}` before sending.
  """
  @spec call(String.t(), map(), timeout: timeout()) :: {:ok, term()} | {:error, term()}
  def call(name, args \\ %{}, opts \\ []) when is_binary(name) and is_map(args) do
    :wasm.host_call(name, args, opts)
  end
end
