defmodule ServiceRadar.Admission.FlowSupervisor do
  @moduledoc false

  use Supervisor

  alias ServiceRadar.Admission.FlowLane
  alias ServiceRadar.Admission.FlowTaskSupervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      Supervisor.child_spec(
        {Task.Supervisor, name: FlowTaskSupervisor},
        id: FlowTaskSupervisor
      ),
      FlowLane
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end
end
