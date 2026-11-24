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

  test "a Lua run replays from its requests" do
    order = %{"id" => "order-1", "items" => [%{"unit_price_cents" => 2500, "quantity" => 2}]}

    # 2026-01-01T00:00:00Z, then an hour later. The transform count makes
    # each result depend on the requests before it.
    requests = [
      {:transform, order},
      {:receipt, %{"id" => "order-1"}, 1_767_225_600, 123_456},
      # Rejected without restarting the worker, which would reset the count.
      {:receipt, %{"id" => "order-1"}, 1_767_225_600, "123456"},
      {:transform, order},
      {:receipt, %{"id" => "order-2"}, 1_767_229_200, 654_321}
    ]

    run = fn ->
      vm = start_vm(app: example("lua"))
      Enum.map(requests, &Kettlecorn.call(vm, :lua_example, &1))
    end

    first = run.()

    assert first == [
             {:ok, {:ok, ["order-1", 5000, "standard", 1]}},
             {:ok, {:ok, ["order-1", 1_767_225_600, 1_769_817_600, 123_456]}},
             {:ok, {:error, "issued_at and code must be integers"}},
             {:ok, {:ok, ["order-1", 5000, "standard", 2]}},
             {:ok, {:ok, ["order-2", 1_767_229_200, 1_769_821_200, 654_321]}}
           ]

    assert run.() == first
  end

  test "Dune evaluates code that can't observe the clock, randomness, or other processes" do
    vm = start_vm(app: example("dune"), preload: :strict, owner: self())
    eval = &Kettlecorn.call(vm, :dune_example, {:eval, &1}, 15_000)

    assert {:ok, {:ok, "6", ""}} = eval.("x = 1 + 2; x * 2")
    assert {:ok, {:ok, "7", ""}} = eval.("defmodule M do def f(x), do: x + 4 end; M.f(x)")

    for code <- [
          "receive do _ -> :ok end",
          "spawn(fn -> :ok end)",
          "self()",
          "DateTime.utc_now()",
          ":erlang.monotonic_time()",
          "Enum.random([1, 2])",
          ":rand.uniform()",
          ":rand.seed_s(:exsss)",
          ":rand.uniform_s(:rand.seed_s(:exsss, 1))",
          "Process.sleep(1)"
        ] do
      assert {:ok, {:error, :restricted, _message}} = eval.(code), code
    end

    task = Task.async(fn -> eval.(~S|Kettlecorn.Host.call("double", %{"n" => 21})|) end)
    assert_receive {:kettlecorn, ^vm, {:host_call, reply_to, "double", %{"n" => 21}}}, 15_000
    :ok = Kettlecorn.reply(vm, reply_to, {:ok, 42})
    assert {:ok, {:ok, "{:ok, 42}", ""}} = Task.await(task, 15_000)

    # A seed from the host determines every draw.
    draw = ~S"""
    {:ok, seed} = Kettlecorn.Host.call("seed")
    {n, _state} = :rand.uniform_s(1_000_000, :rand.seed_s(:exsss, seed))
    n
    """

    [first, second] =
      for _run <- 1..2 do
        task = Task.async(fn -> eval.(draw) end)
        assert_receive {:kettlecorn, ^vm, {:host_call, reply_to, "seed", %{}}}, 15_000
        :ok = Kettlecorn.reply(vm, reply_to, {:ok, 42})
        assert {:ok, {:ok, value, ""}} = Task.await(task, 15_000)
        value
      end

    assert first == second
  end

  test "rejects a directory that isn't a cooked app" do
    assert_raise ArgumentError, ~r/not a compatible cooked application/, fn ->
      Kettlecorn.Sandbox.new(TestRuntime.opts(app: System.tmp_dir!()))
    end
  end
end
