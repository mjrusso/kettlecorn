defmodule Kettlecorn.Host do
  @moduledoc """
  Sends messages and requests from the guest to its host.

    * `send/1` sends a term to the host. An Elixir host delivers it to the
      VM's `:owner` as `{:kettlecorn, vm, {:message, term}}`. A Rust host
      delivers it through `Vm::subscribe` or `VmOptions::events`.
    * `call/3` asks the host to do something and waits for the answer: a
      *host call*. On Elixir, configure named functions with `:handlers` or a
      `Kettlecorn.HostHandler` with `:handler`. With manual delivery, the
      VM's owner answers using `Kettlecorn.reply/3`. On Rust, register an
      async function under `name` with `VmOptions::register`.

  An Elixir host sends messages to guest processes with `Kettlecorn.send/4`;
  they arrive as `{:wasm, payload}`. Both APIs can call and cast to registered
  guest processes through the guest proxy.

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
  `{:error, :frame_too_large}` before sending. After a call returns
  `{:error, :timeout}`, the guest tells the host to cancel it and drops a
  reply that arrives later. A call made while the guest's host-call process
  isn't running, before the guest's applications start (for example from an
  `@on_load` callback during preload) or while that process restarts, gets a
  late reply in its mailbox instead, as `{:wasm, {token, result}}`, and
  isn't cancelled if its caller exits. If that process stops while a call
  waits, the call is cancelled and returns `{:error, :interrupted}`; the host
  may already have handled it. A `:timeout` other than `:infinity` or an
  integer from 0 to 4,294,967,295, the longest `receive` accepts, raises
  `ArgumentError` before the call is sent.
  """
  @spec call(String.t(), map(), timeout: timeout()) :: {:ok, term()} | {:error, term()}
  def call(name, args \\ %{}, opts \\ []) when is_binary(name) and is_map(args) do
    case Keyword.get(opts, :timeout, 5_000) do
      timeout when timeout == :infinity or timeout in 0..4_294_967_295 ->
        Kettlecorn.HostCalls.call(name, args, timeout)

      timeout ->
        raise ArgumentError, "invalid host call timeout: #{inspect(timeout)}"
    end
  end
end
