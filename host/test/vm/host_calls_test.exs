defmodule Kettlecorn.VM.HostCallsTest do
  use ExUnit.Case, async: true

  alias Kettlecorn.VM.HostCalls

  # The test process stands in for the VM and the handler process.
  defp handler_calls, do: %HostCalls{handler: self(), max: 4}

  test "a call reusing a live token is dropped" do
    {[], calls} = HostCalls.call(handler_calls(), self(), "t", "first", %{})
    assert_received {:"$kettlecorn_host_call", {_vm, _id, "t"}, "first", %{}}

    assert {[], ^calls} = HostCalls.call(calls, self(), "t", "second", %{})
  end

  test "a reply names its call by id, not by the guest's token" do
    vm = self()
    {[], calls} = HostCalls.call(handler_calls(), vm, "t", "first", %{})
    assert_received {:"$kettlecorn_host_call", {^vm, first, "t"} = from, "first", %{}}
    {[], calls} = HostCalls.handle(calls, vm, {:ack, first, :noreply})

    calls = HostCalls.cancel(calls, vm, "t")
    assert_received {:"$kettlecorn_host_call_cancel", ^from}

    # The guest reuses the token for a new call, which waits until the
    # handler has handled the cancel notice.
    {[], calls} = HostCalls.call(calls, vm, "t", "second", %{})
    refute_received {:"$kettlecorn_host_call", _from, "second", _args}
    {[], calls} = HostCalls.handle(calls, vm, :cancel_ack)
    assert_received {:"$kettlecorn_host_call", {^vm, second, "t"}, "second", %{}}

    assert {[], ^calls} = HostCalls.handle(calls, vm, {:reply, first, "late"})
    assert {["answer"], _calls} = HostCalls.handle(calls, vm, {:reply, second, "answer"})
  end

  test "a cancelled call keeps its slot until the busy handler has handled the cancellation" do
    vm = self()
    calls = %HostCalls{handler: self(), max: 2}
    {[], calls} = HostCalls.call(calls, vm, "a", "deferred", %{})
    assert_received {:"$kettlecorn_host_call", {^vm, a, "a"} = from, "deferred", %{}}
    {[], calls} = HostCalls.handle(calls, vm, {:ack, a, :noreply})
    {[], calls} = HostCalls.call(calls, vm, "b", "busy", %{})
    assert_received {:"$kettlecorn_host_call", {^vm, b, "b"}, "busy", %{}}

    # The handler is busy, so the cancel notice waits, and the cancelled
    # call still fills a slot: calls and cancellations can't pile up.
    calls = HostCalls.cancel(calls, vm, "a")
    refute_received {:"$kettlecorn_host_call_cancel", _from}
    full = HostCalls.prepare("c", {:error, "host call capacity exhausted"}, nil)
    assert {[^full], calls} = HostCalls.call(calls, vm, "c", "more", %{})

    # The handler hears of the cancellation, which counts until it returns.
    {["done"], calls} = HostCalls.handle(calls, vm, {:ack, b, "done"})
    assert_received {:"$kettlecorn_host_call_cancel", ^from}
    {[], calls} = HostCalls.call(calls, vm, "c", "more", %{})
    full = HostCalls.prepare("d", {:error, "host call capacity exhausted"}, nil)
    assert {[^full], calls} = HostCalls.call(calls, vm, "d", "more", %{})

    # The acknowledgement starts c and frees the cancelled call's slot.
    {[], calls} = HostCalls.handle(calls, vm, :cancel_ack)
    assert_received {:"$kettlecorn_host_call", {^vm, _id, "c"}, "more", %{}}
    assert {[], _calls} = HostCalls.call(calls, vm, "e", "more", %{})
  end

  test "a malformed request gets an error reply unless its token is live" do
    {[], calls} = HostCalls.call(handler_calls(), self(), "t", "first", %{})
    assert HostCalls.reject(calls, "t") == []
    assert [_reply] = HostCalls.reject(calls, "other")
  end
end
