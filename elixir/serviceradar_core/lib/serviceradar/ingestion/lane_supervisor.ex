defmodule ServiceRadar.Ingestion.LaneSupervisor do
  @moduledoc false
  use Supervisor

  alias ServiceRadar.Admission.Lane
  alias ServiceRadar.Ingestion.Admission

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts)

  def child_spec(opts),
    do: %{id: Keyword.fetch!(opts, :type), start: {__MODULE__, :start_link, [opts]}}

  def limits(type) do
    config = Application.get_env(:serviceradar_core, ServiceRadar.Ingestion.Supervisor, [])

    Keyword.merge(
      [
        max_items: 32,
        max_bytes: 32 * 1_024 * 1_024,
        max_items_per_agent: 8,
        queue_wait_ms: 2_000,
        worker_timeout_ms: 10_000,
        gateway_call_timeout_ms: 15_000
      ],
      Keyword.get(config, type, [])
    )
  end

  @impl true
  def init(opts) do
    type = Keyword.fetch!(opts, :type)
    workers = Keyword.fetch!(opts, :workers)
    tasks = {:via, Registry, {ServiceRadar.Ingestion.Registry, {:tasks, type}}}
    config = limits(type)

    children = [
      {Task.Supervisor, name: tasks, max_children: workers},
      {Lane,
       name: Admission.server(type),
       lane: type,
       concurrency: workers,
       task_supervisor: tasks,
       lease_supervisor: ServiceRadar.Ingestion.LeaseSupervisor,
       processor: {Admission, :ingest, []},
       preserve_result: type == :endpoint,
       execution_gate: ServiceRadar.Ingestion.WorkerBudget,
       source_max_bytes: 16 * 1_024 * 1_024,
       gateway_max_ms: 15_000,
       config: config}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end
end
