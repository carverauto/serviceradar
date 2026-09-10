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

  Two things, both required:

    * the `edge_records_publisher` flag is enabled (the same on/off switch every other gateway
      publisher uses, see `ServiceRadarAgentGateway.Application.gateway_publisher_enabled?/0`);
    * every deployment-active publisher lane (`ServiceRadar.Edge.PublisherLane.lanes/0`) has both
      its accountant (`PublisherPool`) and its transport (the named NATS connection) ALIVE.

  Liveness is a proxy for "writable", not proof of it: confirming the JetStream stream/durable
  themselves exist and accept writes needs a broker round trip, which is task 4's scope
  (provisioning) to supply and expose. Until then, a live accountant+transport pair is the
  strongest signal available without adding a per-check broker call to every lane_open.
  """

  alias ServiceRadar.Edge.PublisherLane
  alias ServiceRadar.Edge.PublisherPool

  @capability_id "edge-records:v1"

  @doc "The capability identifier this module gates."
  @spec id() :: String.t()
  def id, do: @capability_id

  @doc """
  Whether the `edge-records:v1` capability is currently ready to advertise/admit.

  False whenever the publisher is disabled, or any deployment-active lane's accountant or
  transport is not alive -- fail closed rather than admit a lane that cannot durably publish.
  """
  @spec ready?() :: boolean()
  def ready? do
    enabled?() and Enum.all?(PublisherLane.lanes(), &lane_ready?/1)
  end

  @doc "Whether the `edge_records_publisher` flag itself is enabled, independent of readiness."
  @spec enabled?() :: boolean()
  def enabled? do
    :serviceradar_agent_gateway
    |> Application.get_env(:edge_records_publisher, [])
    |> Keyword.get(:enabled, false)
  end

  defp lane_ready?(lane) do
    alive?(PublisherPool.via(lane)) and alive?(PublisherLane.connection_name(lane))
  end

  defp alive?(name) when is_atom(name) do
    case Process.whereis(name) do
      pid when is_pid(pid) -> Process.alive?(pid)
      nil -> false
    end
  end
end
