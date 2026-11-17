defmodule Kettlecorn.PropertyTest do
  # Properties of the parsers of guest output, which is untrusted: they must
  # decode what OTP encodes, and never raise, hang or create atoms on
  # anything else. Not async: the atom-table checks need a quiet VM.
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Kettlecorn.{ETF, Pid, Protocol}

  # Loading a module creates atoms: load everything the decoders (and these
  # properties) can touch before measuring the atom table.
  setup_all do
    for app <- [:kettlecorn, :stream_data, :ex_unit, :elixir],
        do: app |> Application.spec(:modules) |> Code.ensure_all_loaded()

    :ok
  end

  # Plain data (what a guest legitimately sends): no pids, ports, refs or funs.
  defp plain_term do
    leaf =
      one_of([
        integer(),
        integer(-(2 ** 80)..(2 ** 80)),
        float(),
        binary(),
        bitstring(),
        string(:printable),
        member_of([:ok, :error, true, false, nil, :"with space", :héllo])
      ])

    tree(leaf, fn child ->
      one_of([
        list_of(child, max_length: 5),
        child |> list_of(max_length: 4) |> map(&List.to_tuple/1),
        map_of(child, child, max_length: 4),
        nonempty(list_of(child, max_length: 3)) |> map(&improper/1)
      ])
    end)
  end

  defp improper(list), do: Enum.reduce(Enum.drop(list, 1), hd(list), &[&1 | &2])

  property "decodes plain data exactly as binary_to_term does" do
    check all(term <- plain_term(), compressed <- boolean()) do
      opts = if compressed, do: [:compressed], else: []
      assert ETF.decode(:erlang.term_to_binary(term, opts)) == {:ok, term}
    end
  end

  property "retained binary allocations fit the reported memory budget" do
    check all(
            term <- plain_term(),
            pids <- list_of(pid_encoding(), max_length: 4),
            atoms <- list_of(unknown_atom_encoding(), min_length: 1, max_length: 3),
            payload <- binary(min_length: 128, max_length: 512),
            compressed <- boolean(),
            max_bytes <- integer(0..4096),
            padding <- integer(0..8192)
          ) do
      <<131, data::binary>> = encode_memory_term(term, pids, atoms, payload)

      etf =
        if compressed,
          do: <<131, 80, byte_size(data)::32, :zlib.compress(data)::binary>>,
          else: <<131, data::binary>>

      # The input may be a slice of a larger binary.
      etf = binary_part(:binary.copy(<<0>>, padding) <> etf, padding, byte_size(etf))

      input_bytes = if compressed, do: byte_size(data), else: byte_size(etf)

      case decode_with_retention(etf, max_bytes) do
        {{:ok, decoded, reported}, retained} ->
          assert decoded ==
                   {term, Enum.map(pids, &%Pid{etf: &1}), Enum.map(atoms, &elem(&1, 1)), payload}

          assert input_bytes <= reported
          assert retained <= reported
          assert reported <= max_bytes

        {{:error, :too_large}, _retained} ->
          :ok
      end
    end
  end

  defp pid_encoding do
    utf8 = String.duplicate("😀", 255)
    latin1 = :binary.copy(<<233>>, 255)
    ascii = String.duplicate("n", 255)

    nodes = [
      <<118, byte_size(utf8)::16, utf8::binary>>,
      <<100, 255::16, latin1::binary>>,
      <<119, 255, ascii::binary>>,
      <<115, 255, latin1::binary>>
    ]

    gen all({tag, bytes} <- member_of([{88, 12}, {103, 9}]), node <- member_of(nodes)) do
      <<131, tag, node::binary, 0::size(bytes * 8)>>
    end
  end

  defp unknown_atom_encoding do
    gen all(
          suffix <- string(:alphanumeric, min_length: 8, max_length: 20),
          count <- integer(64..96),
          tag <- member_of([100, 115, 118, 119])
        ) do
      latin1 = "kettlecorn_mem_" <> suffix <> :binary.copy(<<233>>, count)
      utf8 = :unicode.characters_to_binary(latin1, :latin1)
      name = if tag in [100, 115], do: latin1, else: utf8

      encoded =
        if tag in [100, 118],
          do: <<tag, byte_size(name)::16, name::binary>>,
          else: <<tag, byte_size(name), name::binary>>

      {encoded, {:unknown_atom, utf8}}
    end
  end

  defp encode_memory_term(term, pids, atoms, payload) do
    <<131, plain::binary>> = :erlang.term_to_binary(term)
    handles = IO.iodata_to_binary(Enum.map(pids, fn <<131, handle::binary>> -> handle end))
    names = IO.iodata_to_binary(Enum.map(atoms, &elem(&1, 0)))

    <<131, 104, 4, plain::binary, 108, length(pids)::32, handles::binary, 106, 108,
      length(atoms)::32, names::binary, 106, 109, byte_size(payload)::32, payload::binary>>
  end

  defp decode_with_retention(encoded, max_bytes) do
    owner = self()

    {pid, ref} =
      spawn_monitor(fn ->
        measure_retention(owner, ETF.decode_with_size(encoded, max_bytes: max_bytes))
      end)

    assert_receive {^pid, result, retained}, 1_000
    Process.demonitor(ref, [:flush])
    {result, retained}
  end

  # The worker excludes generator data; its tail call drops the input before GC.
  defp measure_retention(owner, result) do
    :erlang.garbage_collect()
    {:binary, binaries} = Process.info(self(), :binary)
    retained = binaries |> Enum.uniq_by(&elem(&1, 0)) |> Enum.map(&elem(&1, 1)) |> Enum.sum()
    send(owner, {self(), result, retained})
  end

  # minor_version 0 encodes atoms as latin1 ATOM_EXT/SMALL_ATOM_EXT where it
  # can (and floats as FLOAT_EXT, which the decoder rejects: OTP no longer
  # produces it by default).
  property "decodes atoms in their latin1 and UTF-8 encodings" do
    long = String.to_atom(String.duplicate("é", 255))

    check all(
            atom <- member_of([:ok, :héllo, :"with space", long, :日本]),
            minor <- member_of([0, 1, 2])
          ) do
      assert ETF.decode(:erlang.term_to_binary([atom], minor_version: minor)) == {:ok, [atom]}
    end
  end

  property "pids, references and ports anywhere in data decode to handles" do
    handles = [{self(), :pid}, {make_ref(), :reference}, {hd(Port.list()), :port}]

    check all(
            data <- plain_term(),
            {term, kind} <- member_of(handles),
            vm <- member_of([nil, self()]),
            compressed <- boolean(),
            wrap <- member_of([&[&1, data], &{data, &1}, &%{data => &1}])
          ) do
      expected =
        case kind do
          :pid -> %Kettlecorn.Pid{etf: :erlang.term_to_binary(term), vm: vm}
          kind -> %Kettlecorn.Opaque{type: kind}
        end

      encoded = :erlang.term_to_binary(wrap.(term), if(compressed, do: [:compressed], else: []))
      assert ETF.decode(encoded, vm: vm) == {:ok, wrap.(expected)}
    end
  end

  property "maps naming a struct module anywhere in data decode as Kettlecorn.Struct" do
    check all(
            data <- plain_term(),
            module <- member_of([URI, File.Stream, Kettlecorn.Pid, Kettlecorn.Struct, nil]),
            fields <-
              map(
                list_of(tuple({member_of([:path, :etf, :module, :fields]), plain_term()}),
                  max_length: 3
                ),
                &Map.new/1
              ),
            wrap <- member_of([&[&1, data], &{data, &1}, &%{data => &1}, &%{key: &1}])
          ) do
      struct = Map.put(fields, :__struct__, module)
      expected = %Kettlecorn.Struct{module: module, fields: fields}
      assert ETF.decode(:erlang.term_to_binary(wrap.(struct))) == {:ok, wrap.(expected)}
    end
  end

  property "never raises on arbitrary bytes, and creates no atoms" do
    check all(bytes <- binary(), max_runs: 500) do
      before = :erlang.system_info(:atom_count)
      assert_result(ETF.decode(<<131>> <> bytes))
      assert_result(ETF.decode(bytes))
      assert :erlang.system_info(:atom_count) == before
    end
  end

  property "never raises on corrupted encodings of real terms, and creates no atoms" do
    check all(
            term <- plain_term(),
            encoded = :erlang.term_to_binary(term),
            position <- integer(0..max(byte_size(encoded) - 1, 0)),
            byte <- integer(0..255),
            cut <- integer(1..byte_size(encoded))
          ) do
      before = :erlang.system_info(:atom_count)
      <<prefix::binary-size(^position), _, suffix::binary>> = encoded
      assert_result(ETF.decode(prefix <> <<byte>> <> suffix))
      assert_result(ETF.decode(binary_part(encoded, 0, cut)))
      assert :erlang.system_info(:atom_count) == before
    end
  end

  property "never raises on corrupted encodings of pids, references, ports and funs" do
    encodings =
      for term <- [self(), make_ref(), hd(Port.list()), fn -> :x end, {self(), [make_ref()]}],
          opts <- [[], [:compressed]],
          do: :erlang.term_to_binary(term, opts)

    check all(
            encoded <- member_of(encodings),
            position <- integer(0..(byte_size(encoded) - 1)),
            byte <- integer(0..255),
            cut <- integer(1..byte_size(encoded))
          ) do
      <<prefix::binary-size(^position), _, suffix::binary>> = encoded
      assert_result(ETF.decode(prefix <> <<byte>> <> suffix))
      assert_result(ETF.decode(binary_part(encoded, 0, cut)))
    end
  end

  property "unknown atoms come back as {:unknown_atom, name}, without being created" do
    check all(suffix <- string(:alphanumeric, min_length: 8, max_length: 20)) do
      name = "kettlecorn_property_" <> suffix
      # ATOM_UTF8_EXT, built by hand so that the atom never exists here.
      encoded = <<131, 118, byte_size(name)::16, name::binary>>
      before = :erlang.system_info(:atom_count)
      assert ETF.decode(encoded) == {:ok, {:unknown_atom, name}}
      assert :erlang.system_info(:atom_count) == before
    end
  end

  property "message envelopes decode to their kind" do
    check all(data <- plain_term()) do
      decode = &Protocol.decode(<<3, :erlang.term_to_binary(&1)::binary>>, 64 * 1024 * 1024)

      assert decode.(%{type: :vm_message, data: data}) == {:message, data}

      assert decode.(%{type: :host_call, reply_to: "to", name: "name", args: data}) ==
               {:host_call, "to", "name", data}

      event = %{type: :kettlecorn, event: :proxy_reply, id: 1, result: data}
      assert decode.(%{type: :vm_message, data: event}) == {:message, event}
    end
  end

  test "boot events decode and unknown or incomplete events are ignored" do
    for event <- [:boot_ready, :boot_failed] do
      frame = <<3, :erlang.term_to_binary(%{type: :kettlecorn, event: event})::binary>>
      assert Protocol.decode(frame, 1024) == event
    end

    for event <- [
          %{event: :future_event},
          %{event: :proxy_reply, id: 1},
          %{event: :proxy_reply, result: {:ok, 1}}
        ] do
      frame = <<3, :erlang.term_to_binary(Map.put(event, :type, :kettlecorn))::binary>>
      assert Protocol.decode(frame, 1024) == :unknown
    end
  end

  property "proxy replies preserve their id and result" do
    check all(id <- integer(0..0xFFFFFFFF), tag <- member_of([:ok, :error]), data <- plain_term()) do
      result = {tag, data}
      envelope = %{type: :kettlecorn, event: :proxy_reply, id: id, result: result}
      frame = <<3, :erlang.term_to_binary(envelope)::binary>>
      assert Protocol.decode(frame, 64 * 1024 * 1024) == {:proxy_reply, id, result}
    end
  end

  property "malformed proxy results remain replies to the same call" do
    check all(
            id <- integer(0..0xFFFFFFFF),
            result <-
              filter(plain_term(), fn result ->
                not match?({tag, _} when tag in [:ok, :error], result)
              end)
          ) do
      envelope = %{type: :kettlecorn, event: :proxy_reply, id: id, result: result}
      frame = <<3, :erlang.term_to_binary(envelope)::binary>>

      assert Protocol.decode(frame, 64 * 1024 * 1024) ==
               {:proxy_reply, id, {:error, {:bad_reply, result}}}
    end
  end

  test "message decoding enforces the memory budget on compressed payloads" do
    envelope = %{type: :vm_message, data: :binary.copy("x", 4096)}
    frame = <<3, :erlang.term_to_binary(envelope, [:compressed])::binary>>
    assert byte_size(frame) < 1024
    assert Protocol.decode(frame, 1024) == {:error, :too_large}
    assert Protocol.decode(frame, 8192) == {:message, envelope.data}
  end

  property "anything else in a message frame is an error, never a raise" do
    check all(
            body <-
              one_of([
                binary(),
                map(plain_term(), &:erlang.term_to_binary/1),
                map(plain_term(), &:erlang.term_to_binary(%{type: :host_call, reply_to: &1}))
              ])
          ) do
      assert {:error, _} = Protocol.decode(<<3, body::binary>>, 64 * 1024 * 1024)
    end
  end

  property "frame decoding never raises or creates atoms" do
    check all(frame <- binary(), max_bytes <- integer(0..4096)) do
      before = :erlang.system_info(:atom_count)

      for bytes <- [frame, <<3, frame::binary>>] do
        result = Protocol.decode(bytes, max_bytes)
        assert is_tuple(result) or result in [:boot_ready, :boot_failed, :unknown]
      end

      assert :erlang.system_info(:atom_count) == before
    end
  end

  property "VM frames decode to their fields" do
    check all(
            data <- binary(),
            id <- integer(0..0xFFFFFFFF),
            status <- integer(0..4)
          ) do
      assert Protocol.decode(<<1, data::binary>>, 1024) == {:stdout, data}
      assert Protocol.decode(<<2, data::binary>>, 1024) == {:stderr, data}
      assert Protocol.decode(<<4, data::binary>>, 1024) == {:fatal, data}
      assert {:send_result, ^id, _} = Protocol.decode(<<5, id::32, status>>, 1024)
    end
  end

  property "call frames preserve their fields" do
    check all(
            timeout <- one_of([integer(0..1_000_000), constant(:infinity)]),
            id <- integer(0..0xFFFFFFFF),
            target <- binary(),
            request <- plain_term()
          ) do
      prepared = Protocol.prepare_call(target, request, timeout)
      frame = Protocol.send_frame(id, prepared) |> IO.iodata_to_binary()

      assert <<16, ^id::32, 2, size::32, proxy::binary-size(size), payload::binary>> = frame
      assert proxy == "kettlecorn_proxy"

      assert ETF.decode(payload) ==
               {:ok,
                %{
                  "kind" => "call",
                  "target" => target,
                  "request" => request,
                  "proxy_timeout_ms" => timeout
                }}
    end
  end

  property "frames split back into their bodies, however the bytes arrive" do
    check all(
            bodies <- list_of(binary(), max_length: 5),
            cuts <- list_of(integer(0..32), max_length: 30)
          ) do
      stream = bodies |> Enum.map(&Protocol.frame([&1])) |> IO.iodata_to_binary()

      {head, decoder, rest} =
        Enum.reduce(cuts, {[], {:header, ""}, stream}, fn cut, {bodies, decoder, bytes} ->
          cut = min(cut, byte_size(bytes))
          <<record::binary-size(^cut), rest::binary>> = bytes
          assert {:ok, complete, decoder} = Protocol.split(record, 1_000_000, decoder)
          {bodies ++ complete, decoder, rest}
        end)

      assert {:ok, tail, {:header, ""}} = Protocol.split(rest, 1_000_000, decoder)
      assert head ++ tail == bodies
    end
  end

  property "incremental frame splitting never raises or creates atoms, and enforces the limit" do
    check all(records <- list_of(binary(), max_length: 10), max <- integer(0..64)) do
      before = :erlang.system_info(:atom_count)

      result =
        Enum.reduce_while(records, {:ok, [], {:header, ""}}, fn record, {:ok, bodies, decoder} ->
          case Protocol.split(record, max, decoder) do
            {:ok, complete, decoder} -> {:cont, {:ok, bodies ++ complete, decoder}}
            {:error, _reason} = error -> {:halt, error}
          end
        end)

      assert :erlang.system_info(:atom_count) == before

      case result do
        {:ok, bodies, _decoder} ->
          assert Enum.all?(bodies, &(is_binary(&1) and byte_size(&1) <= max))

        {:error, {:frame_too_large, length}} ->
          assert length > max
      end
    end
  end

  defp assert_result(result) do
    assert match?({:ok, _}, result) or match?({:error, _}, result)
  end
end
