defmodule ServiceRadar.EventWriter.CoordinatorSupervisor do
  @moduledoc """
  The EventWriter duties that need one owner per deployment. The coordinator
  runs this tree; every core replica, the coordinator included, also runs the
  workers under `ServiceRadar.EventWriter.Supervisor`.

  ## Children

  1. `EventWriter.ConsumerReconciler` - creates and reconciles every stream and
     durable, retires old durables and runs the stream ownership timer
  2. `EventWriter.CoordinatorPipeline` - the streams whose processors rely on
     one writer (`ServiceRadar.EventWriter.Config.coordinator_stream?/1`). It
     uses the node-local caches the worker tree on the same node owns.
  3. `EventWriter.ConsumerLagReporter` - server-side backlog of every durable,
     reported once rather than once per replica
  4. `FlowAttribution.Correlator` - the periodic flow correlation pass
  """

  use Supervisor

  alias ServiceRadar.EventWriter.Config
  alias ServiceRadar.EventWriter.ConsumerReconciler

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    owned = ConsumerReconciler.default_config()

    children =
      [{ConsumerReconciler, config: owned}]
      |> ServiceRadar.EventWriter.Supervisor.maybe_pipeline(
        Config.for_coordinator(Config.load()),
        ServiceRadar.EventWriter.CoordinatorPipeline
      )
      |> Kernel.++([
        {ServiceRadar.EventWriter.ConsumerLagReporter, owned},
        ServiceRadar.FlowAttribution.Correlator
      ])

    Supervisor.init(children, strategy: :one_for_one)
  end
end
