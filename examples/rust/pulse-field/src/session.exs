defmodule PulseField.Session do
  use GenServer

  def start(board), do: GenServer.start(__MODULE__, board, name: __MODULE__)

  @impl true
  def init(board), do: {:ok, apply(Bot, :init, [board])}

  @impl true
  def handle_call({:frame, view}, _from, state) do
    {drawing, next} = apply(Bot, :frame, [view, state])
    {:links, links} = Process.info(self(), :links)
    {:reply, {drawing, Enum.count(links, &is_pid/1)}, next}
  end
end

{source, file, board} = setup
Code.eval_string(source, [], file: file)
{:ok, _} = PulseField.Session.start(board)
:ok
