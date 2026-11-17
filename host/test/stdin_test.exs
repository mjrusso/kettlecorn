defmodule Kettlecorn.StdinTest do
  use ExUnit.Case, async: true

  @moduletag :integration
  @moduletag timeout: 120_000

  defp start_vm do
    {:ok, vm} = Kettlecorn.start_link(TestRuntime.opts(owner: self()))
    on_exit(fn -> Kettlecorn.stop(vm) end)
    vm
  end

  test "a replacement TTY reader receives input left pending by an exited reader" do
    vm = start_vm()

    # These tuple layouts depend on user_drv/prim_tty internals in OTP 29.
    assert {:ok, _} =
             Kettlecorn.eval(vm, """
             {_, driver} = :sys.get_state(:user_drv)
             tty = elem(driver, 1)
             :ok = :prim_tty.disable_reader(tty)
             :persistent_term.put(:stdin_test_tty, tty)
             """)

    assert :ok = Kettlecorn.write_stdin(vm, "pending input")

    code = """
    tty = :persistent_term.get(:stdin_test_tty)
    :ok = :prim_tty.enable_reader(tty)
    stopped = :prim_tty.reader_stop(tty)
    Process.register(self(), :stdin_test_reader_owner)
    replacement = :prim_tty.reinit(stopped, %{input: :raw, output: :cooked})
    %{read: ref} = :prim_tty.handles(replacement)
    :ok = :prim_tty.read(replacement, 13)
    result = receive do
      {^ref, {:data, data}} -> data
    after
      5_000 -> :timeout
    end
    :prim_tty.reader_stop(replacement)
    result
    """

    assert {:ok, %{"value" => "pending input"}} = Kettlecorn.eval(vm, code, timeout: 10_000)
  end

  test "unread stdin larger than the old ring buffer does not block calls" do
    vm = start_vm()

    assert {:ok, _} =
             Kettlecorn.eval(vm, """
             defmodule StdinCounter do
               use GenServer
               def init(n), do: {:ok, n}
               def handle_call(:increment, _from, n), do: {:reply, n + 1, n + 1}
             end
             GenServer.start(StdinCounter, 0, name: :stdin_counter)
             """)

    input = String.duplicate("x", 256 * 1024)

    for n <- 1..3 do
      assert :ok = Kettlecorn.write_stdin(vm, input)
      assert {:ok, ^n} = Kettlecorn.call(vm, :stdin_counter, :increment)
    end
  end

  test "partial reads preserve bytes across chunks before EOF" do
    vm = start_vm()
    first = String.duplicate("a", 70_001)
    second = String.duplicate("b", 70_003)
    assert :ok = Kettlecorn.write_stdin(vm, first)
    assert :ok = Kettlecorn.write_stdin(vm, second)
    assert :ok = Kettlecorn.close_stdin(vm)

    code = """
    user = Process.whereis(:user)
    {IO.binread(user, 3), IO.binread(user, 100_000), IO.binread(user, :eof), IO.binread(user, 1)}
    """

    middle = String.duplicate("a", 69_998) <> String.duplicate("b", 30_002)
    rest = String.duplicate("b", 40_001)

    assert {:ok, %{"value" => {"aaa", ^middle, ^rest, :eof}}} = Kettlecorn.eval(vm, code)
  end

  test "a stale TTY notification waits for input instead of closing stdin" do
    vm = start_vm()

    # Tuple layouts and readiness messages follow user_drv/prim_tty in OTP 29.
    code = """
    {_, driver} = :sys.get_state(:user_drv)
    tty = elem(driver, 1)
    {reader, ref} = elem(tty, 2)
    send(reader, {:read, 1})
    send(reader, {:select, elem(tty, 1), ref, :ready_input})
    :ok = :prim_tty.disable_reader(tty)
    :ok = :prim_tty.enable_reader(tty)
    Kettlecorn.Host.send(:stdin_waiting)
    IO.binread(Process.whereis(:user), 1)
    """

    read = Task.async(fn -> Kettlecorn.eval(vm, code) end)
    assert_receive {:kettlecorn, ^vm, {:message, :stdin_waiting}}, 5_000
    assert :ok = Kettlecorn.write_stdin(vm, "x")
    assert {:ok, %{"value" => "x"}} = Task.await(read)
  end

  test "closing stdin without data wakes a pending read" do
    vm = start_vm()

    read = Task.async(fn -> Kettlecorn.eval(vm, "IO.read(Process.whereis(:user), 1)") end)

    assert :ok = Kettlecorn.close_stdin(vm)
    assert {:ok, %{"value" => :eof}} = Task.await(read)
  end
end
