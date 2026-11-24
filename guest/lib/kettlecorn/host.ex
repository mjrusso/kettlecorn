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

  Returns the host's `{:ok, value}` or `{:error, reason}`.
  Set `:timeout` to `:infinity` or an integer from 0 to 4,294,967,295 ms.
  It defaults to 5,000 ms. Invalid values raise `ArgumentError` before
  sending. If the frame size check fails, the call returns
  `{:error, :frame_too_large}`.

  A timeout sends a cancellation notice and returns `{:error, :timeout}`.
  When calls go through the reply router, the guest discards late replies
  and cancels pending calls when their callers exit. If the router stops
  during a call, the caller sends a cancellation notice and returns
  `{:error, :interrupted}`. The host may already have handled the call.

  Before the router starts, such as during a preload `@on_load` callback,
  or while it restarts, replies go straight to the caller. A late reply
  can remain in its mailbox as `{:wasm, {token, result}}`, and caller
  exit sends no cancellation notice.
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
