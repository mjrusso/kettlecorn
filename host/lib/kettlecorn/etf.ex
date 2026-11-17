defmodule Kettlecorn.ETF do
  @moduledoc """
  A strict decoder for terms produced by the (untrusted) guest VM.

  `:erlang.binary_to_term/2` with `[:safe]` is unsuitable for guest data:

    * it decodes pids, ports and references into *live host terms*: a guest
      pid with the host's node name can identify a host process;
    * it decodes local funs referencing host modules;
    * it fails on any atom the host doesn't know.

  This decoder only produces plain data. Atoms are returned when they already
  exist on the host and as `{:unknown_atom, name}` tuples otherwise, so a
  guest can never grow the host's atom table. Pids become `Kettlecorn.Pid`
  handles for addressing the guest. Ports and references become
  `Kettlecorn.Opaque` placeholders with no usable identity. Funs are rejected.

  A map whose `:__struct__` is an atom would be a struct of that module on
  the host, and protocols dispatch on it: a guest could send a
  `%File.Stream{}` with a path of its choice, and host code enumerating it
  would read that file. Such maps decode as `Kettlecorn.Struct`, which holds
  the module and the other fields as data.

  Nesting depth and element counts are bounded. The `:max_bytes` budget
  (default 64 MiB) charges retained binary data in full and estimates the
  heap space for each decoded node; exceeding it returns `:too_large`.
  Input slices are copied so decoded binaries cannot retain unrelated data.
  PID handle copies and retained UTF-8 conversions of Latin-1 atom names
  are charged separately.
  For compressed terms, the budget counts the inflated data, and terms larger
  than `:max_bytes` are rejected. A list of empty lists, for instance, takes 16 bytes
  of heap per byte of input on a 64-bit host.
  """

  alias Kettlecorn.{ETF.Inflate, Opaque, Pid, Struct}

  @max_depth 512
  @default_max_bytes 64 * 1024 * 1024
  # NEW_PID_EXT, PID_EXT, V4_PORT_EXT, NEW_PORT_EXT: the bytes after the node.
  @handles %{88 => {:pid, 12}, 103 => {:pid, 9}, 120 => {:port, 12}, 89 => {:port, 8}}
  # Approximate heap words per node: a boxed float; a sub-binary; a struct
  # with a binary in it; {:unknown_atom, name}.
  @float_words 3
  @binary_words 6
  @handle_words 16
  @unknown_atom_words 3 + @binary_words

  @type decode_error :: :badarg | :too_deep | :too_large | {:unsupported, atom()}

  @doc """
  Decodes `binary`. Option `:max_bytes` sets the budget for retained binary
  data and estimated heap space (default 64 MiB). Option `:vm` binds PID handles
  to their originating VM; the default produces unbound handles.
  """
  @spec decode(binary(), keyword()) :: {:ok, term()} | {:error, decode_error()}
  def decode(binary, opts \\ []) do
    case decode_with_size(binary, opts) do
      {:ok, term, _size} -> {:ok, term}
      {:error, _reason} = error -> error
    end
  end

  @doc false
  @spec decode_with_size(binary(), keyword()) ::
          {:ok, term(), non_neg_integer()} | {:error, decode_error()}
  def decode_with_size(binary, opts) do
    max_bytes = Keyword.get(opts, :max_bytes, @default_max_bytes)
    vm = Keyword.get(opts, :vm)

    case binary do
      <<131, 80, size::32, _::binary>> when size > max_bytes ->
        {:error, :too_large}

      <<131, 80, size::32, compressed::binary>> ->
        case Inflate.inflate(compressed, size) do
          {:ok, data} -> decode_root(data, data, max_bytes, vm)
          :error -> {:error, :badarg}
        end

      <<131, _::binary>> when byte_size(binary) > max_bytes ->
        {:error, :too_large}

      <<131, _::binary>> ->
        <<131, rest::binary>> = binary = unshared(binary)
        decode_root(rest, binary, max_bytes, vm)

      _ ->
        {:error, :badarg}
    end
  end

  # Input may be a slice of a larger binary. Without a copy, decoded binaries
  # retain that whole binary, beyond the input budget.
  defp unshared(binary) do
    if :binary.referenced_byte_size(binary) > byte_size(binary),
      do: :binary.copy(binary),
      else: binary
  end

  # `retained` (what the term's binaries keep alive, at most `max_bytes`) is
  # charged before any node.
  defp decode_root(data, retained, max_bytes, vm) do
    budget = {div(max_bytes - byte_size(retained), :erlang.system_info(:wordsize)), vm}

    case term(data, 0, budget) do
      {term, <<>>, {remaining, _vm}} ->
        {:ok, term, max_bytes - remaining * :erlang.system_info(:wordsize)}

      {_term, _trailing, _budget} ->
        {:error, :badarg}
    end
  catch
    {:etf_error, reason} -> {:error, reason}
  end

  defp fail(reason), do: throw({:etf_error, reason})

  # The budget left after taking `words` from it; containers charge before
  # they decode their elements, so nothing large is built past the budget.
  defp charge({budget, _vm}, words) when words > budget, do: fail(:too_large)
  defp charge({budget, vm}, words), do: {budget - words, vm}

  defp charge_bytes(b, bytes) do
    wordsize = :erlang.system_info(:wordsize)
    charge(b, div(bytes + wordsize - 1, wordsize))
  end

  defp term(_data, depth, _b) when depth > @max_depth, do: fail(:too_deep)

  # SMALL_INTEGER_EXT, INTEGER_EXT (immediates, on a 64-bit host), NEW_FLOAT_EXT
  defp term(<<97, i, rest::binary>>, _d, b), do: {i, rest, b}
  defp term(<<98, i::signed-32, rest::binary>>, _d, b), do: {i, rest, b}
  defp term(<<70, f::float-64, rest::binary>>, _d, b), do: {f, rest, charge(b, @float_words)}

  # SMALL_BIG_EXT, LARGE_BIG_EXT
  defp term(<<110, n, sign, digits::binary-size(n), rest::binary>>, _d, b),
    do: {big(sign, digits), rest, charge(b, 2 + div(n, 8))}

  defp term(<<111, n::32, sign, digits::binary-size(n), rest::binary>>, _d, b) do
    if n > 1024 * 1024, do: fail(:too_large)
    {big(sign, digits), rest, charge(b, 2 + div(n, 8))}
  end

  # ATOM_UTF8_EXT and ATOM_EXT (latin1), SMALL_ATOM_UTF8_EXT and SMALL_ATOM_EXT
  defp term(<<tag, n::16, name::binary-size(n), rest::binary>>, _d, b) when tag in [118, 100],
    do: atom(tag, name, rest, b)

  defp term(<<tag, n, name::binary-size(n), rest::binary>>, _d, b) when tag in [119, 115],
    do: atom(tag, name, rest, b)

  # SMALL_TUPLE_EXT, LARGE_TUPLE_EXT
  defp term(<<104, n, rest::binary>>, d, b), do: tuple(n, rest, d, b)
  defp term(<<105, n::32, rest::binary>>, d, b), do: tuple(n, rest, d, b)

  # NIL_EXT, STRING_EXT, LIST_EXT
  defp term(<<106, rest::binary>>, _d, b), do: {[], rest, b}

  defp term(<<107, n::16, chars::binary-size(n), rest::binary>>, _d, b),
    do: {:binary.bin_to_list(chars), rest, charge(b, 2 * n)}

  defp term(<<108, n::32, rest::binary>>, d, b) do
    check_count(n, rest)
    b = charge(b, 2 * n)
    {elems, rest, b} = elements(n, rest, d + 1, b, [])
    {tail, rest, b} = term(rest, d + 1, b)
    {build_list(elems, tail), rest, b}
  end

  # BINARY_EXT, BIT_BINARY_EXT
  defp term(<<109, n::32, bin::binary-size(n), rest::binary>>, _d, b),
    do: {bin, rest, charge(b, @binary_words)}

  defp term(<<77, n::32, bits, bin::binary-size(n), rest::binary>>, _d, b) when bits in 1..8 do
    b = charge(b, @binary_words)

    if n == 0 do
      {<<>>, rest, b}
    else
      keep = (n - 1) * 8 + bits
      <<bs::bitstring-size(^keep), _::bitstring>> = bin
      {bs, rest, b}
    end
  end

  # MAP_EXT
  defp term(<<116, n::32, rest::binary>>, d, b) do
    check_count(2 * n, rest)
    b = charge(b, 3 + 3 * n)
    {kvs, rest, b} = elements(2 * n, rest, d + 1, b, [])

    case pairs(kvs, %{}) do
      %{__struct__: module} = map when is_atom(module) ->
        {%Struct{module: module, fields: Map.delete(map, :__struct__)}, rest,
         charge(b, @handle_words)}

      map ->
        {map, rest, b}
    end
  end

  defp term(<<tag, rest::binary>> = all, d, b) when is_map_key(@handles, tag) do
    {kind, size} = Map.fetch!(@handles, tag)
    {_node, after_node, b} = node(rest, d + 1, b)
    rest = skip(after_node, size)
    etf = binary_part(all, 0, byte_size(all) - byte_size(rest))
    {handle, b} = handle(kind, etf, charge(b, @handle_words))
    {handle, rest, b}
  end

  # NEWER_REFERENCE_EXT (90), NEW_REFERENCE_EXT (114): len 4-byte ids after
  # the node and its creation (4 bytes, or 1 for the older tag).
  defp term(<<tag, len::16, rest::binary>>, d, b) when tag in [90, 114] do
    {_node, after_node, b} = node(rest, d + 1, b)
    creation = if tag == 90, do: 4, else: 1
    {%Opaque{type: :reference}, skip(after_node, creation + len * 4), charge(b, @handle_words)}
  end

  defp term(<<tag, _::binary>>, _d, _b) when tag in [112, 113, 117],
    do: fail({:unsupported, :fun})

  defp term(_data, _d, _b), do: fail(:badarg)

  defp skip(bin, n) when byte_size(bin) >= n, do: binary_part(bin, n, byte_size(bin) - n)
  defp skip(_bin, _n), do: fail(:badarg)

  defp check_count(n, rest) do
    # Every element takes at least one byte; reject impossible counts early.
    if n > byte_size(rest), do: fail(:badarg)
  end

  defp tuple(n, rest, d, b) do
    check_count(n, rest)
    b = charge(b, n + 1)
    {elems, rest, b} = elements(n, rest, d + 1, b, [])
    {List.to_tuple(elems), rest, b}
  end

  defp elements(0, rest, _d, b, acc), do: {Enum.reverse(acc), rest, b}

  defp elements(n, rest, d, b, acc) do
    {t, rest, b} = term(rest, d, b)
    elements(n - 1, rest, d, b, [t | acc])
  end

  defp build_list(elems, []), do: elems
  defp build_list(elems, tail), do: :lists.foldr(fn e, acc -> [e | acc] end, tail, elems)

  defp pairs([], acc), do: acc
  defp pairs([k, v | rest], acc), do: pairs(rest, Map.put(acc, k, v))

  defp big(sign, digits) do
    n = :binary.decode_unsigned(digits, :little)
    if sign == 0, do: n, else: -n
  end

  defp node(<<tag, _::binary>> = data, d, b) when tag in [100, 115, 118, 119],
    do: term(data, d, b)

  defp node(_data, _d, _b), do: fail(:badarg)

  defp handle(:pid, etf, {_budget, vm} = b) do
    b = charge_bytes(b, byte_size(etf) + 1)
    {%Pid{etf: <<131, etf::binary>>, vm: vm}, b}
  end

  defp handle(:port, _etf, b), do: {%Opaque{type: :port}, b}

  # ATOM_EXT and SMALL_ATOM_EXT names are latin1.
  defp atom(tag, name, rest, b) when tag in [100, 115] do
    utf8 = :unicode.characters_to_binary(name, :latin1)
    existing_atom(utf8, rest, b, byte_size(utf8))
  end

  defp atom(_tag, name, rest, b), do: existing_atom(name, rest, b, 0)

  defp existing_atom(name, rest, b, copied_bytes) do
    {String.to_existing_atom(name), rest, b}
  rescue
    ArgumentError ->
      b = b |> charge(@unknown_atom_words) |> charge_bytes(copied_bytes)
      {{:unknown_atom, name}, rest, b}
  end
end
