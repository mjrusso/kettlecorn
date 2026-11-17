defmodule Kettlecorn.VMTest do
  use ExUnit.Case, async: true

  alias Kettlecorn.Protocol
  alias Kettlecorn.VM
  alias Kettlecorn.VM.Requests

  test "an infinite request is released when its caller dies" do
    caller = spawn(fn -> receive do: (:stop -> :ok) end)
    on_exit(fn -> Process.exit(caller, :kill) end)
    from = {caller, make_ref()}

    request =
      {:request, :call, nil, Protocol.prepare_call("missing", "request", :infinity), :infinity}

    assert {:noreply, state} = VM.handle_call(request, from, %VM{port: self()})
    assert_receive {_, {:command, _frame}}
    Process.exit(caller, :kill)
    assert_receive {:DOWN, _, :process, ^caller, _} = down
    assert {:noreply, state} = VM.handle_info(down, state)
    assert state.requests.entries == %{}
  end

  test "admission is bounded after frames leave the input queue" do
    state = %VM{port: self(), requests: Requests.new(2)}
    from = {self(), make_ref()}
    {:noreply, state} = VM.handle_call(request(:call), from, state)
    {:noreply, state} = VM.handle_call(request(:send), from, state)
    assert_receive {_, {:command, _}}
    assert_receive {_, {:command, _}}
    assert :queue.is_empty(state.input)

    for kind <- [:call, :send] do
      assert {:reply, {:error, :request_queue_full}, ^state} =
               VM.handle_call(request(kind), from, state)
    end

    refute_receive {_, {:command, _}}
    Requests.fail_all(state.requests, :normal)
  end

  test "caller exit releases all of its requests and cancels finite deadlines" do
    caller = spawn(fn -> receive do: (:stop -> :ok) end)
    on_exit(fn -> Process.exit(caller, :kill) end)
    from = {caller, make_ref()}
    {:noreply, state} = VM.handle_call(request(:call, 60_000), from, %VM{port: self()})
    {:noreply, state} = VM.handle_call(request(:send, 60_000), from, state)
    timers = for {_, {_, _, _, timer}} <- state.requests.entries, do: timer
    Process.exit(caller, :kill)

    state =
      Enum.reduce(1..2, state, fn _, state ->
        assert_receive {:DOWN, _, :process, ^caller, _} = down
        {:noreply, state} = VM.handle_info(down, state)
        state
      end)

    assert state.requests.entries == %{}
    assert state.requests.monitors == %{}
    assert Enum.all?(timers, &(Process.read_timer(&1) == false))
  end

  test "deadline releases capacity and a stale deadline cannot expire a reused ID" do
    state = %VM{port: self(), requests: Requests.new(1)}
    tag = make_ref()
    {:noreply, state} = VM.handle_call(request(:call, 0), {self(), tag}, state)
    assert_receive {:deadline, id, monitor} = deadline
    assert {:noreply, state} = VM.handle_info(deadline, state)
    assert_receive {^tag, {:error, :timeout}}
    assert state.requests.monitors == %{}
    refute {:process, self()} in elem(Process.info(self(), :monitors), 1)

    state = %{state | requests: %{state.requests | next_id: id}}
    {:noreply, state} = VM.handle_call(request(:send), {self(), tag}, state)
    assert {:noreply, ^state} = VM.handle_info(deadline, state)
    assert {:noreply, ^state} = VM.handle_info({:DOWN, monitor, :process, self(), :normal}, state)
    Requests.fail_all(state.requests, :normal)
  end

  test "VM failure releases requests, timers and caller monitors" do
    state = %VM{port: self()}
    first = make_ref()
    second = make_ref()
    {:noreply, state} = VM.handle_call(request(:call, 60_000), {self(), first}, state)
    {:noreply, state} = VM.handle_call(request(:send, 60_000), {self(), second}, state)
    timers = for {_, {_, _, _, timer}} <- state.requests.entries, do: timer

    assert {:stop, {:shutdown, {:vm_down, :timeout}}, state} =
             VM.handle_info(:max_lifetime, state)

    assert_receive {^first, {:error, {:vm_down, :timeout}}}
    assert_receive {^second, {:error, {:vm_down, :timeout}}}
    assert state.requests.entries == %{}
    assert state.requests.monitors == %{}
    assert Enum.all?(timers, &(Process.read_timer(&1) == false))
    refute {:process, self()} in elem(Process.info(self(), :monitors), 1)
  end

  test "ID allocation wraps and skips pending requests for casts" do
    state = %VM{port: self(), requests: %Requests{next_id: 0xFFFF_FFFF}}
    {:noreply, state} = VM.handle_call(request(:call), {self(), make_ref()}, state)
    assert_receive {_, {:command, first}}
    assert <<_length::32, _type, 0xFFFF_FFFF::32, _rest::binary>> = IO.iodata_to_binary(first)
    state = %{state | requests: %{state.requests | next_id: 0xFFFF_FFFF}}
    {:noreply, state} = VM.handle_cast({:send, Protocol.prepare("missing", "cast")}, state)
    assert_receive {_, {:command, second}}
    assert <<_length::32, _type, 0::32, _rest::binary>> = IO.iodata_to_binary(second)
    Requests.fail_all(state.requests, :normal)
  end

  defp request(kind, timeout \\ :infinity) do
    prepared =
      if kind == :call,
        do: Protocol.prepare_call("missing", "request", timeout),
        else: Protocol.prepare("missing", "request")

    {:request, kind, nil, prepared, timeout}
  end
end
