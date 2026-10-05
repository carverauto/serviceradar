defmodule ServiceRadar.AgentCommands.ConsumerWorker do
  @moduledoc """
  Serializes one command-result consumer independently of command persistence.

  A lane also receives that consumer's ack/progress callbacks, so terminal
  results cannot overtake earlier updates for the same command. The five
  consumers have independent mailboxes and bounded execution concurrency.
  """

  use GenServer

  alias ServiceRadar.AgentCommands.StatusSupervisor

  def start_link(opts) do
    lane = Keyword.fetch!(opts, :lane)
    GenServer.start_link(__MODULE__, lane, name: StatusSupervisor.worker_name({:consumer, lane}))
  end

  def enqueue(lane, work) when is_function(work, 0) do
    GenServer.cast(StatusSupervisor.worker_pid!({:consumer, lane}), {:consume, work})
  end

  @impl true
  def init(lane), do: {:ok, lane}

  @impl true
  def handle_cast({:consume, work}, lane) do
    work.()
    {:noreply, lane}
  end
end
