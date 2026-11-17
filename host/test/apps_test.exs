defmodule Kettlecorn.AppsTest do
  use ExUnit.Case, async: true

  @moduletag :integration
  @moduletag :examples
  @moduletag timeout: 120_000

  defp example(name), do: Path.join(System.fetch_env!("KETTLECORN_EXAMPLES"), name)

  defp start_vm(opts) do
    {:ok, vm} = Kettlecorn.start_link(TestRuntime.opts(opts))
    on_exit(fn -> Kettlecorn.stop(vm) end)
    vm
  end

  test "a cooked app reads configuration at boot and retains state between calls" do
    vm = start_vm(app: example("counter"))

    assert {:ok, 10} = Kettlecorn.call(vm, :counter, :value)
    assert {:ok, 11} = Kettlecorn.call(vm, :counter, :increment)
    assert {:ok, 11} = Kettlecorn.call(vm, :counter, :value)
  end

  test "a cooked app with a Hex dependency" do
    vm = start_vm(app: example("csv_stats"))

    assert {:ok, %{"value" => [{"east", 948.0} | _], "output" => output}} =
             Kettlecorn.eval(vm, "CsvStats.report(); CsvStats.by_region()")

    assert output =~ "Revenue by region (EUR):"
  end

  test "a cooked Lua interpreter transforms orders and retains script state" do
    vm = start_vm(app: example("lua"))

    event = %{
      "id" => "order-1",
      "email" => "ada@example.test",
      "items" => [
        %{"unit_price_cents" => 2500, "quantity" => 2},
        %{"unit_price_cents" => 1500, "quantity" => 1}
      ]
    }

    assert {:ok, {:ok, ["order-1", 6500, "standard", 1]}} =
             Kettlecorn.call(vm, :lua_example, {:transform, event})

    priority = %{event | "items" => [%{"unit_price_cents" => 12_500, "quantity" => 1}]}

    assert {:ok, {:ok, ["order-1", 12_500, "priority", 2]}} =
             Kettlecorn.call(vm, :lua_example, {:transform, priority})

    assert {:ok, {:error, _message}} =
             Kettlecorn.call(vm, :lua_example, {:transform, %{"id" => "invalid"}})

    assert {:ok, {:ok, ["order-1", 6500, "standard", 3]}} =
             Kettlecorn.call(vm, :lua_example, {:transform, event})
  end

  test "rejects a directory that isn't a cooked app" do
    assert_raise ArgumentError, ~r/not a compatible cooked application/, fn ->
      Kettlecorn.Sandbox.new(TestRuntime.opts(app: System.tmp_dir!()))
    end
  end
end
