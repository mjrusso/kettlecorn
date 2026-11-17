defmodule Kettlecorn.ProtocolTest do
  use ExUnit.Case, async: true

  alias Kettlecorn.Protocol

  test "fragmented headers reject oversized frames as soon as the length is known" do
    for cut <- 0..3 do
      <<first::binary-size(^cut), last::binary>> = <<65_537::32>>
      assert {:ok, [], decoder} = Protocol.split(first, 65_536)

      assert Protocol.split(last, 65_536, decoder) ==
               {:error, {:frame_too_large, 65_537}}
    end
  end

  test "completes a large frame across capped records and resumes at the next header" do
    body = :binary.copy(<<0, 1, 2, 3>>, 262_144)
    stream = IO.iodata_to_binary([Protocol.frame([body]), Protocol.frame(["next"]), <<0, 0>>])

    {frames, decoder} =
      stream
      |> Stream.unfold(fn
        <<>> ->
          nil

        bytes ->
          size = min(65_536, byte_size(bytes))
          <<record::binary-size(^size), rest::binary>> = bytes
          {record, rest}
      end)
      |> Enum.reduce({[], {:header, ""}}, fn record, {frames, decoder} ->
        assert {:ok, complete, decoder} = Protocol.split(record, byte_size(body), decoder)
        {frames ++ complete, decoder}
      end)

    assert frames == [body, "next"]

    assert {:ok, ["", "end"], {:header, ""}} =
             Protocol.split(<<0, 0, 3::32, "end">>, byte_size(body), decoder)
  end

  test "accepts empty records between bytes of headers and bodies" do
    stream = IO.iodata_to_binary([Protocol.frame([""]), Protocol.frame(["abc"])])

    {frames, decoder} =
      for(<<byte <- stream>>, record <- [<<>>, <<byte>>], do: record)
      |> Enum.reduce({[], {:header, ""}}, fn record, {frames, decoder} ->
        assert {:ok, complete, decoder} = Protocol.split(record, 3, decoder)
        {frames ++ complete, decoder}
      end)

    assert frames == ["", "abc"]
    assert decoder == {:header, ""}
  end
end
