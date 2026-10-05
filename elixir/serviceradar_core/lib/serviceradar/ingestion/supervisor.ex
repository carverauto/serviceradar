defmodule ServiceRadar.Ingestion.Supervisor do
  @moduledoc false
  use Supervisor

  alias ServiceRadar.Ingestion.LaneSupervisor
  alias ServiceRadar.Inventory.SyncIngestorQueue

  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    lanes = [
      sweep: 4,
      mapper: 2,
      bumblebee: 2,
      legacy_plugin: 2,
      endpoint: 4,
      other_results: 2,
      status: 2
    ]

    validate_memory_budget!(Keyword.keys(lanes))

    children = [
      {Registry, keys: :unique, name: ServiceRadar.Ingestion.Registry},
      ServiceRadar.Ingestion.WorkerBudget,
      task_supervisor(ServiceRadar.Ingestion.ServiceStateTaskSupervisor, 1),
      ServiceRadar.ResultsRouter,
      ServiceRadar.Admission.FlowSupervisor,
      ServiceRadar.Admission.RetainedPluginSupervisor,
      task_supervisor(ServiceRadar.SyncIngestor.TaskSupervisor, 1),
      SyncIngestorQueue
      | Enum.map(lanes, fn {type, workers} -> {LaneSupervisor, type: type, workers: workers} end)
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end

  defp validate_memory_budget!(lanes) do
    config = Application.get_env(:serviceradar_core, __MODULE__, [])
    # Reserve space for decoding and model construction as well as raw queues.
    # The supported core deployment has an 8 GiB limit; ingestion owns at most
    # half. Operators with smaller cores must lower the queue limits together.
    budget = Keyword.get(config, :memory_budget_bytes, 4 * 1_024 * 1_024 * 1_024)
    reserve = Keyword.get(config, :memory_reserve_bytes, 512 * 1_024 * 1_024)
    amplification = Keyword.get(config, :decode_amplification, 8)

    raw_bytes =
      Enum.reduce(lanes, 0, fn lane, total ->
        total + Keyword.fetch!(LaneSupervisor.limits(lane), :max_bytes)
      end) + Keyword.fetch!(ServiceRadar.Admission.FlowLane.limits(), :max_bytes) +
        Keyword.fetch!(ServiceRadar.Admission.RetainedPluginLane.limits(), :max_bytes) +
        Keyword.get(
          Application.get_env(:serviceradar_core, SyncIngestorQueue, []),
          :max_bytes,
          64 * 1_024 * 1_024
        ) +
        Application.get_env(:serviceradar_core, :results_router_max_bytes, 32 * 1_024 * 1_024)

    if !(is_integer(budget) and budget > 0 and is_integer(reserve) and reserve >= 0 and
           is_integer(amplification) and amplification >= 8 and
           raw_bytes * amplification + reserve <= budget) do
      raise ArgumentError, "ingestion memory budget cannot cover raw queues and decode reserve"
    end
  end

  defp task_supervisor(name, max_children) do
    Supervisor.child_spec({Task.Supervisor, name: name, max_children: max_children}, id: name)
  end
end
