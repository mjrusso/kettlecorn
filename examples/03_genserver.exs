# Run bank account GenServers under a supervisor.

defmodule Bank.Account do
  use GenServer

  def start_link(name), do: GenServer.start_link(__MODULE__, 0, name: via(name))
  def deposit(name, amount), do: GenServer.call(via(name), {:deposit, amount})
  def withdraw(name, amount), do: GenServer.call(via(name), {:withdraw, amount})
  def balance(name), do: GenServer.call(via(name), :balance)
  def crash(name), do: GenServer.cast(via(name), :crash)

  defp via(name), do: {:via, Registry, {Bank.Registry, name}}

  @impl true
  def init(balance), do: {:ok, balance}

  @impl true
  def handle_call({:deposit, amount}, _from, balance) when amount > 0,
    do: {:reply, {:ok, balance + amount}, balance + amount}

  def handle_call({:withdraw, amount}, _from, balance) when amount <= balance,
    do: {:reply, {:ok, balance - amount}, balance - amount}

  def handle_call({:withdraw, _amount}, _from, balance),
    do: {:reply, {:error, :insufficient_funds}, balance}

  def handle_call(:balance, _from, balance), do: {:reply, balance, balance}

  @impl true
  def handle_cast(:crash, _balance), do: raise("simulated failure")
end

children = [
  {Registry, keys: :unique, name: Bank.Registry},
  {DynamicSupervisor, name: Bank.Accounts, strategy: :one_for_one}
]

{:ok, _sup} = Supervisor.start_link(children, strategy: :one_for_one)

for name <- ["alice", "bob"] do
  {:ok, _pid} =
    DynamicSupervisor.start_child(Bank.Accounts, %{
      id: name,
      start: {Bank.Account, :start_link, [name]}
    })
end

IO.inspect(Bank.Account.deposit("alice", 100), label: "alice deposits 100")
IO.inspect(Bank.Account.withdraw("alice", 30), label: "alice withdraws 30")
IO.inspect(Bank.Account.withdraw("bob", 10), label: "bob withdraws 10")

# Concurrent clients: 100 tasks each deposit 1 into bob's account.
1..100
|> Task.async_stream(fn _ -> Bank.Account.deposit("bob", 1) end, max_concurrency: 20)
|> Stream.run()

IO.inspect(Bank.Account.balance("bob"), label: "bob after 100 concurrent deposits")

# Crash the account; the supervisor restarts it with a fresh state.
[{old_pid, _}] = Registry.lookup(Bank.Registry, "alice")
Logger.configure(level: :none)
Bank.Account.crash("alice")
Process.sleep(50)
[{new_pid, _}] = Registry.lookup(Bank.Registry, "alice")
IO.puts("alice crashed and was restarted: #{inspect(old_pid)} -> #{inspect(new_pid)}")
IO.inspect(Bank.Account.balance("alice"), label: "alice's balance after restart")
