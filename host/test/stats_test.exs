defmodule Kettlecorn.VM.StatsTest do
  use ExUnit.Case, async: true

  alias Kettlecorn.VM.Stats

  test "accepts a record whose checksum matches, as PROTOCOL.md documents" do
    assert Stats.decode(record(123, 456, 0x2481F22F5C03602E)) == {:ok, {123, 456}}
    assert Stats.decode(<<0::192>>) == {:ok, {0, 0}}
  end

  test "rejects a record that mixes two updates" do
    assert Stats.decode(record(124, 456, 0x2481F22F5C03602E)) == :error
    assert Stats.decode(<<0::128>>) == :error
  end

  defp record(fuel, memory, checksum),
    do: <<fuel::little-64, memory::little-64, checksum::little-64>>
end
