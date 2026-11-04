defmodule ServiceRadarAgentGateway.EdgeRecordCapability do
  @moduledoc """
  Readiness gate for the `edge-records:v1` capability (unify-sweep-results-proto task 3.1).

  There is no separate wire advertisement channel for this capability yet -- the Hello-RPC
  negotiation described by `ServiceRadar.Edge.HelloCapabilities` /
  `Serviceradar.Edge.V1.EdgeRecordCapabilitiesV1` belongs to a later increment. Until it lands,
  the RPC server's own admission behavior IS the advertisement: `EdgeRecordIngestServer` consults
  `ready?/0` before accepting a lane and refuses to open one while it is false, so an agent cannot
  observe the capability as present before it actually is.

  ## What "ready" means here

  Three things, all required. The pipeline has no on/off switch (enable-edge-record-pipeline-by-
  default, design Decision 1), so readiness is only whether this gateway can authorize and
  durably publish:

    * a local trust snapshot is installed (`ServiceRadarAgentGateway.EdgeRecordTrust`), because no
      frame can be authorized without one and the gateway never asks core per frame;
    * every deployment-active publisher lane (`ServiceRadar.Edge.PublisherLane.lanes/0`) has its
      accountant (`PublisherPool`), its transport (the named NATS connection) and its
      `PublishPipeline` ALIVE -- the pipeline being what the ingest server offers every frame to;
    * that snapshot carries a verified contract registry
      (`ServiceRadarAgentGateway.EdgeRecordTrust.registry_available?/0`). Without one every frame
      is withheld, so admitting a lane would advertise a capability that cannot publish anything.

  Liveness is a proxy for "writable", not proof of it: confirming the JetStream stream/durable
  themselves exist and accept writes needs a broker round trip, which is task 4's scope
  (provisioning) to supply and expose. Until then, a live accountant+transport pair is the
  strongest signal available without adding a per-check broker call to every lane_open.
  """

  alias ServiceRadar.Edge.PublisherLane
  alias ServiceRadar.Edge.PublisherPool
  alias ServiceRadar.Edge.PublishPipeline
  alias ServiceRadarAgentGateway.EdgeRecordTrust

  @capability_id "edge-records:v1"

  @doc "The capability identifier this module gates."
  @spec id() :: String.t()
  def id, do: @capability_id

  @doc """
  Whether the `edge-records:v1` capability is currently ready to advertise/admit.

  False whenever no trust snapshot is installed, any deployment-active lane's accountant,
  transport or pipeline is not alive, or the snapshot carries no verified contract registry --
  fail closed rather than admit a lane that cannot authorize or durably publish.
  """
  @spec ready?() :: boolean()
  def ready? do
    EdgeRecordTrust.available?() and Enum.all?(PublisherLane.lanes(), &lane_ready?/1) and
      EdgeRecordTrust.registry_available?()
  end

  defp lane_ready?(lane) do
    alive?(PublisherPool.via(lane)) and alive?(PublisherLane.connection_name(lane)) and
      alive?(PublishPipeline.via(lane))
  end

  defp alive?(name) when is_atom(name) do
    case Process.whereis(name) do
      pid when is_pid(pid) -> Process.alive?(pid)
      nil -> false
    end
  end
end
