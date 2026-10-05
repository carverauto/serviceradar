defmodule ServiceRadar.Admission.RetainedPluginSupervisor do
  @moduledoc false

  use Supervisor

  alias ServiceRadar.Admission.RetainedPluginLane
  alias ServiceRadar.Admission.RetainedPluginTaskSupervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      Supervisor.child_spec(
        {Task.Supervisor, name: RetainedPluginTaskSupervisor, max_children: 2},
        id: RetainedPluginTaskSupervisor
      ),
      {RetainedPluginLane, execution_gate: ServiceRadar.Ingestion.WorkerBudget}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end
end
