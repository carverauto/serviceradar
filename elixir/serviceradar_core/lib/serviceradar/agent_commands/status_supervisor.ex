defmodule ServiceRadar.AgentCommands.StatusSupervisor do
  @moduledoc false

  use Supervisor

  alias ServiceRadar.AgentCommands.ConsumerWorker
  alias ServiceRadar.AgentCommands.PersistenceWorker
  alias ServiceRadar.AgentCommands.StatusHandler

  @registry ServiceRadar.AgentCommands.WorkerRegistry
  @default_shards 8

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts)

  def worker_name(key), do: {:via, Registry, {@registry, key}}

  def worker_pid!(key) do
    case Registry.lookup(@registry, key) do
      [{pid, _value}] -> pid
      [] -> exit({:command_status_worker_unavailable, key})
    end
  end

  @impl true
  def init(opts) do
    shards =
      Keyword.get(
        opts,
        :shards,
        Application.get_env(:serviceradar_core, :agent_command_status_shards, @default_shards)
      )

    if is_integer(shards) and shards in 1..64 do
      consumer_count =
        Enum.max([
          5,
          length(Keyword.get(opts, :result_consumers, [])),
          length(Keyword.get(opts, :progress_consumers, []))
        ])

      consumers =
        for lane <- 0..(consumer_count - 1) do
          Supervisor.child_spec({ConsumerWorker, lane: lane}, id: {:consumer, lane})
        end

      persisters =
        for shard <- 0..(shards - 1) do
          worker_opts = Keyword.put(opts, :name, worker_name({:persistence, shard}))
          Supervisor.child_spec({PersistenceWorker, worker_opts}, id: {:persistence, shard})
        end

      children = [
        {Registry, keys: :unique, name: @registry},
        pool_spec(:consumers, consumers),
        pool_spec(:persistence, persisters),
        %{
          id: :ingress,
          start: {StatusHandler, :start_ingress_link, [[shards: shards]]}
        }
      ]

      # Registry replacement invalidates all names. A pool replacement also
      # restarts the ingress that depends on it; individual workers restart
      # independently inside their pools.
      Supervisor.init(children, strategy: :rest_for_one)
    else
      raise ArgumentError, "agent_command_status_shards must be between 1 and 64"
    end
  end

  defp pool_spec(id, children) do
    %{
      id: id,
      start: {Supervisor, :start_link, [children, [strategy: :one_for_one]]},
      type: :supervisor,
      shutdown: :infinity
    }
  end
end
