defmodule Kettlecorn.OptionsTest do
  use ExUnit.Case, async: true

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
