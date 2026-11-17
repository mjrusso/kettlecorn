defmodule Kettlecorn.OptionsTest do
  use ExUnit.Case, async: true

  test "pending request limit must be a positive integer" do
    for limit <- [0, -1, :infinity, 1.5] do
      assert_raise ArgumentError, ~r/:max_pending_requests option/, fn ->
        Kettlecorn.start(max_pending_requests: limit)
      end
    end
  end

  test "invalid evaluation options raise before sending a request to the VM" do
    for {key, value} <- [timeout: -1, timeout: 1.5, binding: :invalid, language: :gleam] do
      assert_raise ArgumentError, ~r/#{inspect(key)} option/, fn ->
        Kettlecorn.eval(self(), "1", [{key, value}])
      end
    end

    assert_raise ArgumentError, ~r/unknown options.*:timeuot/, fn ->
      Kettlecorn.eval(self(), "1", timeuot: 100)
    end
  end
end
