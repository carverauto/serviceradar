defmodule ServiceRadar.NATS.ManagedCertificateSupervisor do
  @moduledoc """
  Supervises the deployment certificate authorizer, its dedicated NATS
  connections, and the recorder for the chart's rotated runtime certificates.
  """
  use Supervisor

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    Supervisor.init(
      [
        {DynamicSupervisor,
         name: ServiceRadar.NATS.CertificateConnections, strategy: :one_for_one},
        {Task.Supervisor, name: ServiceRadar.NATS.CertificateObservationTasks, max_children: 1},
        ServiceRadar.NATS.ManagedCertificateAuthorization,
        ServiceRadar.Edge.RuntimeCertificateRotation
      ],
      strategy: :rest_for_one
    )
  end
end
