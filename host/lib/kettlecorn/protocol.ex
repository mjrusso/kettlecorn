defmodule Kettlecorn.Protocol do
  @moduledoc false
  alias Kettlecorn.ETF

  # Keep frame types and layouts in sync with c/include/kettlecorn.h and
  # PROTOCOL.md. split/3 checks guest lengths before assembling frames from
  # capped transport records; direct {:packet, 4} framing of guest data would
  # allocate the length claimed by the guest.

  # The flake records this version in each runtime's manifest. Bump it for
  # incompatible framing, envelope, event, proxy, boot, or cooked-app changes.
  @version_file Path.expand("../../PROTOCOL_VERSION", __DIR__)
  @external_resource @version_file
  @version @version_file |> File.read!() |> String.trim() |> String.to_integer()

  def version, do: @version

  # VM -> host
  @stdout 1
  @stderr 2
  @message 3
  @fatal 4
  @send_result 5
  # host -> VM
  @send 16
  @stdin 17
  @stdin_eof 19

  @target_name 0
  @target_pid 1
  @target_proxy 2
  @max_input 64 * 1024 * 1024
  @event_overhead 16 * :erlang.system_info(:wordsize)

  def max_input_size, do: @max_input

  @proxy "kettlecorn_proxy"

  def split(data, max, decoder \\ {:header, ""}), do: split_frames(data, max, decoder, [])

  defp split_frames(data, _max, {:header, header}, acc)
       when byte_size(header) + byte_size(data) < 4,
       do: {:ok, Enum.reverse(acc), {:header, header <> data}}

  defp split_frames(data, max, {:header, header}, acc) do
    needed = 4 - byte_size(header)
    <<part::binary-size(^needed), rest::binary>> = data
    <<length::32>> = header <> part

    if length > max,
      do: {:error, {:frame_too_large, length}},
      else: split_frames(rest, max, {:body, length, []}, acc)
  end

  defp split_frames(<<>>, _max, {:body, remaining, _chunks} = decoder, acc)
       when remaining > 0,
       do: {:ok, Enum.reverse(acc), decoder}

  # Matching a growing body binary forces its next append to copy all prior bytes.
  defp split_frames(data, _max, {:body, remaining, chunks}, acc)
       when byte_size(data) < remaining,
       do: {:ok, Enum.reverse(acc), {:body, remaining - byte_size(data), [data | chunks]}}

  defp split_frames(data, max, {:body, remaining, chunks}, acc) do
    <<part::binary-size(^remaining), rest::binary>> = data
    body = [part | chunks] |> Enum.reverse() |> :erlang.iolist_to_binary()
    split_frames(rest, max, {:header, ""}, [body | acc])
  end

  def frame(body), do: [<<:erlang.iolist_size(body)::32>> | body]

  defp check_size!(size) when size <= @max_input, do: :ok
  defp check_size!(_size), do: raise(ArgumentError, "host frames cannot exceed 64 MiB")

  def decode(body, max_bytes), do: body |> decode(max_bytes, nil) |> elem(0)

  def decode(<<@message, etf::binary>>, max_bytes, vm) do
    case ETF.decode_with_size(etf, max_bytes: max_bytes, vm: vm) do
      {:ok, term, size} -> {envelope(term), size + @event_overhead}
      {:error, reason} -> {{:error, reason}, 0}
    end
  end

  def decode(body, _max_bytes, _vm),
    do: {decode_raw(body), :binary.referenced_byte_size(body) + @event_overhead}

  defp decode_raw(<<@stdout, data::binary>>), do: {:stdout, data}
  defp decode_raw(<<@stderr, data::binary>>), do: {:stderr, data}
  defp decode_raw(<<@fatal, text::binary>>), do: {:fatal, text}
  defp decode_raw(<<@send_result, id::32, status>>), do: {:send_result, id, send_status(status)}
  defp decode_raw(_other), do: :unknown

  defp envelope(%{type: :vm_message, data: data}), do: {:message, data}

  defp envelope(%{type: :host_call, reply_to: to, name: name, args: args}) when is_binary(to),
    do: {:host_call, to, name, args}

  defp envelope(%{type: :kettlecorn, event: :boot_ready}), do: :boot_ready
  defp envelope(%{type: :kettlecorn, event: :boot_failed}), do: :boot_failed

  defp envelope(%{type: :kettlecorn, event: :proxy_reply, id: id, result: result}),
    do: {:proxy_reply, id, proxy_result(result)}

  defp envelope(%{type: :kettlecorn, event: _}), do: :unknown
  defp envelope(other), do: {:error, {:unknown_envelope, other}}

  def prepare(target, payload) do
    {kind, name} = encode_target(target)
    prepare(kind, name, payload)
  end

  defp prepare(kind, name, payload) do
    etf = :erlang.term_to_binary(payload)
    check_size!(10 + byte_size(name) + byte_size(etf))
    {kind, name, etf}
  end

  def send_frame(id, {kind, name, etf}),
    do: [<<@send, id::32, kind, byte_size(name)::32>>, name, etf]

  def prepare_call(target, request, proxy_timeout) do
    prepare(@target_proxy, @proxy, %{
      "kind" => "call",
      "target" => target,
      "request" => request,
      "proxy_timeout_ms" => proxy_timeout
    })
  end

  def prepare_cast(target, request),
    do:
      prepare(@target_proxy, @proxy, %{"kind" => "cast", "target" => target, "request" => request})

  def prepare_reply(reply_to, result) when is_binary(reply_to),
    do: prepare(@target_pid, reply_to, result)

  def prepare_reply(_reply_to, _result), do: raise(ArgumentError, "reply_to must be a binary")

  def stdin_frame(data) do
    check_size!(1 + :erlang.iolist_size(data))
    [<<@stdin>>, :erlang.iolist_to_binary(data)]
  end

  def stdin_eof_frame, do: [<<@stdin_eof>>]

  defp encode_target(name) when is_binary(name), do: {@target_name, name}
  defp encode_target(%Kettlecorn.Pid{etf: etf}) when is_binary(etf), do: {@target_pid, etf}
  defp encode_target(_target), do: raise(ArgumentError, "invalid guest target")

  defp proxy_result({:ok, _value} = ok), do: ok
  defp proxy_result({:error, _reason} = error), do: error
  defp proxy_result(other), do: {:error, {:bad_reply, other}}

  # enum kettlecorn_send_status in c/include/kettlecorn.h.
  defp send_status(0), do: :ok
  defp send_status(1), do: {:error, :noproc}
  defp send_status(2), do: {:error, :bad_payload}
  defp send_status(_), do: {:error, :bad_request}
end
