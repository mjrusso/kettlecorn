defmodule Kettlecorn.TimeoutTest do
  use ExUnit.Case, async: true

  alias Kettlecorn.Timeout

  test "finite budgets leave time for cleanup and proxy replies" do
    for timeout <- [0, 5_000] do
      request = Timeout.request(timeout)
      assert request.proxy == timeout
      assert request.host > request.proxy

      evaluation = Timeout.evaluation(timeout)
      assert evaluation.evaluation == timeout
      assert evaluation.proxy > timeout
      assert evaluation.host > evaluation.proxy
    end

    evaluation = Timeout.evaluation(0)
    assert evaluation.finish > 0
    assert evaluation.finish < evaluation.proxy - evaluation.evaluation
  end

  test "infinite budgets keep evaluation cleanup bounded" do
    assert %{proxy: :infinity, host: :infinity} = Timeout.request(:infinity)

    assert %{evaluation: :infinity, proxy: :infinity, host: :infinity, finish: finish} =
             Timeout.evaluation(:infinity)

    assert finish in 1..(Timeout.request(0).host - 1)
  end
end
