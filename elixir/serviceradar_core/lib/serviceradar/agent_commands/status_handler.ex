defmodule ServiceRadar.AgentCommands.StatusHandler do
  @moduledoc """
  Routes command updates to persistence shards keyed by command id.

  Each shard preserves ack/progress/result order for a command. Persisted
  updates keep the existing public PubSub contract; consumers run in separate,
  ordered lanes after successful persistence.

  `:agent_command_status_shards` configures the persistence pool (default 8,
  range 1..64). Each result consumer has one worker, keeping its shared
  release, scan or automation state serialized across commands.
  """

  use GenServer

  alias ServiceRadar.AgentCommands.PersistenceWorker
  alias ServiceRadar.AgentCommands.PubSub
  alias ServiceRadar.AgentCommands.StatusSupervisor

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end

  def start_link(opts \\ []), do: StatusSupervisor.start_link(opts)

  @doc false
  def start_ingress_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    :ok = PubSub.subscribe_ingress()
    {:ok, %{shards: Keyword.fetch!(opts, :shards)}}
  end

  @impl true
  def handle_info({kind, data} = message, state)
      when kind in [:command_ack, :command_progress, :command_result] and is_map(data) do
    command_id = Map.get(data, :command_id) || Map.get(data, "command_id")
    shard = :erlang.phash2(command_key(command_id), state.shards)
    send(StatusSupervisor.worker_pid!({:persistence, shard}), message)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # Route textual and binary UUIDs to the same owner, as persistence does.
  defp command_key(command_id) do
    case Ecto.UUID.cast(command_id) do
      {:ok, uuid} -> uuid
      :error ->
        case Ecto.UUID.load(command_id) do
          {:ok, uuid} -> uuid
          :error -> command_id
        end
    end
  end

  @doc false
  defdelegate sanitize_cleanup_result(data), to: PersistenceWorker

  @doc false
  defdelegate log_control_query_failure(action, command_id, reason), to: PersistenceWorker
end
