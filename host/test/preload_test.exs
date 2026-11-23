defmodule Kettlecorn.PreloadTest do
  # Each test boots real VMs in the launcher, see test_helper.exs.
  use ExUnit.Case, async: true

  @moduletag :integration
  @moduletag timeout: 120_000

  # Writes an Erlang module that no VM has loaded to a new code path
  # directory, then calls it so the code server loads it on demand.
  @late_load ~S"""
  forms = [
    {:attribute, 1, :module, :kettlecorn_late},
    {:attribute, 1, :export, [answer: 0]},
    {:function, 1, :answer, 0, [{:clause, 1, [], [], [{:integer, 1, 42}]}]}
  ]

  {:ok, :kettlecorn_late, beam} = :compile.forms(forms)
  File.mkdir_p!("/tmp/late")
  File.write!("/tmp/late/kettlecorn_late.beam", beam)
  :code.add_patha(~c"/tmp/late")
  :kettlecorn_late.answer()
  """

  # The iteration order of a map with atom keys depends on where the atoms
  # sit in the atom table: directly for a small map, through their hashes for
  # a large one. Two boots of the same VM must leave the atoms that boot and
  # preload need, and later ones, in the same places.
  test "two preloaded boots order maps with atom keys the same way" do
    code = ~S"""
    loaded = for {module, _} <- :code.all_loaded(), do: module
    created = for n <- 1..40, do: String.to_atom("kettlecorn_order_#{n}")
    small = Map.new(Enum.take(created, 10), &{&1, 0})
    {Map.keys(Map.new(loaded, &{&1, 0})), Map.keys(Map.new(created, &{&1, 0})), Map.keys(small)}
    """

    [first, second] =
      for _boot <- 1..2 do
        assert {:ok, %{"value" => value}} = Kettlecorn.eval(start_vm(preload: true), code)
        value
      end

    {loaded, _created, _small} = first
    assert Enum.count_until(loaded, 501) > 500
    assert first == second
  end

  # Preload runs @on_load callbacks before the guest's applications start.
  @tag :tmp_dir
  test "a module's @on_load callback can call the host during preload", %{tmp_dir: tmp} do
    build = Path.join(tmp, "build")
    ebin = Path.join([build, "on_load_app", "ebin"])
    File.mkdir_p!(ebin)

    File.write!(
      Path.join(ebin, "on_load_app.app"),
      ~s|{application, on_load_app, [{applications, [kernel, stdlib]}, {modules, [on_load_app]}, {vsn, "0.1.0"}]}.\n|
    )

    # Compiled without loading, so the callback runs only in the guest.
    source = Path.join(tmp, "on_load_app.erl")

    File.write!(source, """
    -module(on_load_app).
    -on_load(ask/0).
    -export([ask/0, answer/0]).
    ask() ->
        {ok, Answer} = 'Elixir.Kettlecorn.Host':call(<<"loaded">>, \#{}),
        persistent_term:put(on_load_app, Answer).
    answer() -> persistent_term:get(on_load_app).
    """)

    {:ok, :on_load_app, beam} = :compile.file(String.to_charlist(source), [:binary])
    File.write!(Path.join(ebin, "on_load_app.beam"), beam)
    app = Path.join(tmp, "app")

    assert {:ok, _} =
             Kettlecorn.Cook.cook(
               app: :on_load_app,
               build: build,
               out: app,
               runtime: TestRuntime.runtime()
             )

    test = self()

    handler = fn _args ->
      send(test, :loaded)
      {:ok, 42}
    end

    vm = start_vm(app: app, preload: :strict, handlers: %{"loaded" => handler})
    assert_received :loaded
    assert {:ok, %{"value" => 42}} = Kettlecorn.eval(vm, ":on_load_app.answer()")
  end

  test "preload loads the code path at boot and reports later loads" do
    vm = start_vm(preload: true)

    assert {:ok, %{"value" => true}} =
             Kettlecorn.eval(
               vm,
               "Enum.all?([Req.Request, :ssl_cipher, IEx], &:erlang.module_loaded/1)"
             )

    assert {:ok, %{"value" => 42}} = Kettlecorn.eval(vm, @late_load)
    assert_receive {:kettlecorn, ^vm, {:late_load, "kettlecorn_late"}}, 5_000
  end

  test "strict preload stops the VM when it loads a module later" do
    vm = start_vm(preload: :strict)
    monitor = Process.monitor(vm)
    Kettlecorn.eval(vm, @late_load)

    assert_receive {:kettlecorn, ^vm, {:late_load, "kettlecorn_late"}}, 5_000

    assert_receive {:kettlecorn, ^vm,
                    {:stderr, "kettlecorn: kettlecorn_late was loaded after preload\n"}},
                   5_000

    # While parallel builds load the machine, a stopped VM can take several
    # seconds to finish shutting down.
    assert_receive {:DOWN, ^monitor, :process, ^vm,
                    {:shutdown, {:vm_down, {:exit_status, 1, _}}}},
                   30_000
  end

  test "without preload, modules load on demand and nothing is reported" do
    vm = start_vm([])

    assert {:ok, %{"value" => false}} =
             Kettlecorn.eval(vm, ":erlang.module_loaded(:ssl_cipher)")

    assert {:ok, %{"value" => 42}} = Kettlecorn.eval(vm, @late_load)
    refute_receive {:kettlecorn, ^vm, {:late_load, _}}, 500
  end

  defp start_vm(opts) do
    {:ok, vm} = Kettlecorn.start(TestRuntime.opts([owner: self()] ++ opts))
    on_exit(fn -> Kettlecorn.stop(vm) end)
    vm
  end
end
