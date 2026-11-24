defmodule Kettlecorn.ETFTest do
  use ExUnit.Case, async: true
  alias Kettlecorn.ETF

  defp roundtrip(term), do: ETF.decode(:erlang.term_to_binary(term))

  test "decodes plain data like binary_to_term" do
    terms = [
      0,
      255,
      -1,
      2 ** 31,
      -(2 ** 70),
      1.5,
      :ok,
      true,
      nil,
      "bin",
      <<1::3>>,
      [],
      [1, 2],
      [1 | 2],
      ~c"chars",
      {},
      {1, {2, "x"}},
      %{"b" => [2], a: 1},
      Map.new(1..40, &{&1, &1}),
      String.duplicate("x", 70_000),
      Enum.to_list(1..1000),
      :héllo
    ]

    for t <- terms, do: assert(roundtrip(t) == {:ok, t})
  end

  test "compressed terms" do
    t = List.duplicate("abc", 10_000)
    assert ETF.decode(:erlang.term_to_binary(t, compressed: 9)) == {:ok, t}
  end

  test "unknown atoms don't grow the atom table" do
    # ATOM_UTF8_EXT for an atom that does not exist on this node.
    name = "kettlecorn_surely_not_an_atom_#{System.unique_integer([:positive])}"
    bin = <<131, 118, byte_size(name)::16, name::binary>>
    assert ETF.decode(bin) == {:ok, {:unknown_atom, name}}
    assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
  end

  test "pids become handles, refs and ports opaque, funs are rejected" do
    assert {:ok, %Kettlecorn.Pid{etf: etf}} = roundtrip(self())
    assert :erlang.binary_to_term(etf) == self()
    assert {:ok, %Kettlecorn.Opaque{type: :reference}} = roundtrip(make_ref())
    assert {:ok, %Kettlecorn.Opaque{type: :port}} = roundtrip(hd(Port.list()))
    assert {:error, {:unsupported, :fun}} = roundtrip(fn -> :ok end)
    assert {:error, {:unsupported, :fun}} = roundtrip(&Enum.map/2)
  end

  test "pid, port and reference nodes must be encoded atoms" do
    for node <- [<<97, 1>>, <<106>>, <<109, 4096::32, 0::size(4096 * 8)>>],
        handle <- [
          <<88, node::binary, 0::96>>,
          <<103, node::binary, 0::72>>,
          <<120, node::binary, 0::96>>,
          <<89, node::binary, 0::64>>,
          <<90, 1::16, node::binary, 0::64>>,
          <<114, 1::16, node::binary, 0::40>>
        ] do
      assert ETF.decode(<<131, handle::binary>>) == {:error, :badarg}
    end
  end

  test "the budget includes the input and every copied PID handle" do
    name = String.duplicate("😀", 255)
    node = <<118, byte_size(name)::16, name::binary>>
    data = :binary.copy("x", 4096)

    for {tag, bytes} <- [{88, 12}, {103, 9}] do
      pid = <<tag, node::binary, 0::size(bytes * 8)>>
      encoded = <<131, 104, 3, 109, byte_size(data)::32, data::binary, pid::binary, pid::binary>>

      assert {:ok, {decoded, first, second}, reported} =
               ETF.decode_with_size(encoded, max_bytes: 32_768)

      retained =
        Enum.sum(Enum.map([decoded, first.etf, second.etf], &:binary.referenced_byte_size/1))

      assert retained <= reported
      assert ETF.decode(encoded, max_bytes: retained - 1) == {:error, :too_large}
      assert {:ok, _} = ETF.decode(encoded, max_bytes: reported)
    end
  end

  test "the budget includes retained Latin-1 atom conversions alongside the input" do
    prefix = "kettlecorn_latin1_#{System.unique_integer([:positive])}"
    name = prefix <> :binary.copy(<<233>>, 255 - byte_size(prefix))
    utf8 = :unicode.characters_to_binary(name, :latin1)
    data = :binary.copy("x", 4096)

    for atom <- [<<100, 255::16, name::binary>>, <<115, 255, name::binary>>] do
      encoded = <<131, 104, 2, 109, byte_size(data)::32, data::binary, atom::binary>>

      assert {:ok, {decoded, {:unknown_atom, ^utf8}}, reported} =
               ETF.decode_with_size(encoded, max_bytes: 8192)

      retained = :binary.referenced_byte_size(decoded) + byte_size(utf8)
      assert retained <= reported
      assert ETF.decode(encoded, max_bytes: retained - 1) == {:error, :too_large}
    end
  end

  test "structs decode as Kettlecorn.Struct, never as structs of host modules" do
    assert {:ok, %Kettlecorn.Struct{module: URI, fields: %{host: "example.com"}}} =
             roundtrip(URI.parse("http://example.com"))

    # The decoder's own handles, forged, are wrapped too.
    assert {:ok, %Kettlecorn.Struct{module: Kettlecorn.Pid, fields: %{etf: "x"}}} =
             roundtrip(%{__struct__: Kettlecorn.Pid, etf: "x"})

    assert {:ok, %Kettlecorn.Struct{module: Kettlecorn.Struct}} =
             roundtrip(%{__struct__: Kettlecorn.Struct, module: URI, fields: %{}})

    assert {:ok, %{__struct__: "URI"}} = roundtrip(%{__struct__: "URI"})
  end

  test "rejects malformed and hostile input" do
    assert {:error, :badarg} = ETF.decode(<<>>)
    assert {:error, :badarg} = ETF.decode(<<131>>)
    assert {:error, :badarg} = ETF.decode(<<131, 255>>)
    assert {:error, :badarg} = ETF.decode(<<1, 2, 3>>)
    # A list claiming 4 billion elements.
    assert {:error, :badarg} = ETF.decode(<<131, 108, 0xFFFFFFFF::32, 106>>)
    # A map claiming 2 billion pairs.
    assert {:error, :badarg} = ETF.decode(<<131, 116, 0x7FFFFFFF::32>>)
    # Trailing garbage.
    assert {:error, :badarg} = ETF.decode(<<131, 97, 1, 0>>)
    # Absurd compressed size.
    assert {:error, :too_large} = ETF.decode(<<131, 80, 0xFFFFFFFF::32, 0>>)
    # A decompression bomb: 64 MiB of zeros in ~64 kB, declared as 100 bytes.
    bomb = :zlib.compress(:binary.copy(<<0>>, 64 * 1024 * 1024))
    assert {:error, :badarg} = ETF.decode(<<131, 80, 100::32, bomb::binary>>)
    # Deep nesting.
    deep = Enum.reduce(1..1000, :x, fn _, acc -> {acc} end)
    assert {:error, :too_deep} = roundtrip(deep)
  end

  test "the memory the decoded term holds is bounded, however small its encoding" do
    # A million empty lists: 1 MB encoded, 16 MB of list cells decoded.
    n = 1_000_000
    nils = <<131, 108, n::32>> <> :binary.copy(<<106>>, n) <> <<106>>
    assert {:error, :too_large} = ETF.decode(nils, max_bytes: 8 * 1024 * 1024)
    assert {:ok, list} = ETF.decode(nils, max_bytes: 32 * 1024 * 1024)
    assert length(list) == n

    compressed = :erlang.term_to_binary(List.duplicate([], n), compressed: 9)
    assert byte_size(compressed) < 10_000
    assert {:error, :too_large} = ETF.decode(compressed, max_bytes: 8 * 1024 * 1024)

    # A compressed binary counts as what it inflates to: the decoded
    # binary keeps the inflated data alive.
    big = :erlang.term_to_binary(:binary.copy(<<0>>, 8 * 1024 * 1024), compressed: 9)
    assert byte_size(big) < 1024 * 1024
    assert {:error, :too_large} = ETF.decode(big, max_bytes: 1024 * 1024)
    assert {:ok, _} = ETF.decode(big, max_bytes: 9 * 1024 * 1024)

    for term <- [List.to_tuple(List.duplicate(0, n)), Map.new(1..div(n, 2), &{&1, 0.5})] do
      assert {:error, :too_large} = ETF.decode(:erlang.term_to_binary(term), max_bytes: 4 * n)
    end
  end

  describe "to_json/1" do
    defp json(term) do
      {:ok, decoded} = roundtrip(term)
      ETF.to_json(decoded)
    end

    test "converts decoded data to what JSON encodes" do
      term = %{
        :ok => {1, 2.5, "three"},
        "list" => [nil, true, false, :atom],
        7 => %URI{host: "example.com"},
        "nested" => %{"empty" => []}
      }

      uri =
        %URI{host: "example.com"}
        |> Map.from_struct()
        |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
        |> Map.put("__struct__", "Elixir.URI")

      assert {:ok, json} = json(term)

      assert json == %{
               "ok" => [1, 2.5, "three"],
               "list" => [nil, true, false, "atom"],
               "7" => uri,
               "nested" => %{"empty" => []}
             }

      assert JSON.decode!(JSON.encode!(json)) == json
    end

    test "names unknown atoms, also as map keys and struct modules" do
      binary = :erlang.term_to_binary(%{:__struct__ => :ok, :ok => :ok})
      unknown = String.replace(binary, "ok", "zq")
      {:ok, decoded} = ETF.decode(unknown)
      assert ETF.to_json(decoded) == {:ok, %{"__struct__" => "zq", "zq" => "zq"}}
    end

    test "names a struct's module with a string, whatever atom it is" do
      assert {:ok, %{"__struct__" => "nil", "a" => 1}} = json(%{__struct__: nil, a: 1})
      assert {:ok, %{"__struct__" => "true"}} = json(%{__struct__: true})
    end

    test "returns an error for data without a JSON form" do
      assert json([self()]) == {:error, {:unsupported, :pid}}
      assert json(%{ref: make_ref()}) == {:error, {:unsupported, :reference}}
      assert json(<<1::3>>) == {:error, {:unsupported, :bitstring}}
      assert json(<<255>>) == {:error, {:unsupported, :invalid_utf8}}
      assert json(%{<<255>> => 1}) == {:error, {:unsupported, :invalid_utf8}}
      # Guest data shaped like an unknown atom gets the same check.
      assert json({:unknown_atom, <<255>>}) == {:error, {:unsupported, :invalid_utf8}}
      assert json(%{{:unknown_atom, <<255>>} => 1}) == {:error, {:unsupported, :invalid_utf8}}
      assert json([1 | 2]) == {:error, {:unsupported, :improper_list}}
      assert json(%{{1} => 1}) == {:error, {:unsupported, :map_key}}
      assert json(%{1.5 => 1}) == {:error, {:unsupported, :map_key}}
      assert json(%{:a => 1, "a" => 2}) == {:error, {:duplicate_key, "a"}}
    end
  end
end
