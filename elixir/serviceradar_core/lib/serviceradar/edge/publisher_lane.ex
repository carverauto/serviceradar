defmodule ServiceRadar.Edge.PublisherLane do
  @moduledoc """
  Which publisher a verified route belongs to, and what that publisher's NATS connection is
  called (unify-sweep-results-proto task 3.3(c) part 3b).

  ## The publisher lane is NOT the wire traffic class

  It is tempting to key the publishers on `EdgeRecordTrafficClass`, because two of the three are
  named after its members. That is wrong in both directions, and the mistake is silent:

    * The wire enum has NO recovery member. It is `UNSPECIFIED`, `BULK`, `INTERACTIVE` -- so a
      traffic class alone can never select the recovery publisher, and code that mapped the enum
      onto publishers would have no lane to put recovery traffic on.
    * Recovery is a ROUTE PROFILE (`EDGE_RECORD_ROUTE_PROFILE_RECOVERY_CONTROL_V1`), and it pairs
      with BOTH traffic classes. `StreamRoute.active_lanes/0` lists four
      `{route_profile, traffic_class}` pairs, and recovery accounts for two of them.

  So the key is the PAIR, collapsed onto three publishers:

      {durable_records, BULK}         -> :bulk
      {durable_records, INTERACTIVE}  -> :interactive
      {recovery_control, BULK}        -> :recovery
      {recovery_control, INTERACTIVE} -> :recovery

  Recovery collapses both classes onto one publisher because it resolves to ONE singular,
  unpartitioned stream (`TELEMETRY_EDGE_RECORD_RECOVERY_V1`) regardless of class -- see
  `StreamRoute.resolve/1`. Splitting it by class would create two publishers for one stream,
  which buys no isolation and costs a connection.

  ## Why this matters for isolation, not just tidiness

  The spec requires the recovery stream to have "separate unborrowable storage, PubAck, and
  consumer capacity". Because the recovery publisher is reachable only through a ROUTE PROFILE,
  and the route profile comes from the effective control-plane grant rather than from the frame,
  an agent cannot ask for recovery capacity. Had the publishers been keyed on the wire traffic
  class, any lane an agent could name would have been a lane it could saturate.

  ## The connection count is bounded BY CONSTRUCTION

  The spec forbids allocating more connections per network scope, agent, producer assignment,
  run, output contract, package, or logical partition. `lanes/0` is a closed three-element list
  and `connection_name/1` accepts nothing else, so the number of publisher connections is three
  no matter how many scopes, agents, or contracts exist. There is no argument that could make it
  grow.
  """

  alias ServiceRadar.Edge.StreamRoute

  @durable_records :EDGE_RECORD_ROUTE_PROFILE_DURABLE_RECORDS_V1
  @recovery_control :EDGE_RECORD_ROUTE_PROFILE_RECOVERY_CONTROL_V1

  @bulk :EDGE_RECORD_TRAFFIC_CLASS_BULK
  @interactive :EDGE_RECORD_TRAFFIC_CLASS_INTERACTIVE

  @lanes [:bulk, :interactive, :recovery]

  @doc """
  The publisher lanes. Closed by design -- see the moduledoc on why this bounds the connection
  count rather than merely documenting it.
  """
  def lanes, do: @lanes

  @doc "The registered name of a lane's NATS publisher connection."
  def connection_name(lane) when lane in @lanes, do: :"serviceradar_nats_publisher_#{lane}"

  @doc """
  The publisher lane for a verified `{route_profile, traffic_class}` pair.

  Takes the pair rather than a whole contract: everything else on a contract (partition rule,
  coordinates) selects a subject WITHIN a lane, never the lane itself, and accepting a map here
  would invite a caller to believe otherwise.
  """
  @spec for_lane(atom(), atom()) :: {:ok, :bulk | :interactive | :recovery} | {:error, atom()}
  def for_lane(@recovery_control, class) when class in [@bulk, @interactive], do: {:ok, :recovery}
  def for_lane(@durable_records, @bulk), do: {:ok, :bulk}
  def for_lane(@durable_records, @interactive), do: {:ok, :interactive}
  def for_lane(_profile, _class), do: {:error, :unroutable_lane}

  @doc """
  Every deployment-active pair paired with its publisher lane.

  Derived from `StreamRoute.active_lanes/0` rather than restated, so a lane added there without a
  publisher shows up as a crash here instead of as traffic quietly published on some other lane's
  connection.
  """
  def active_assignments do
    Enum.map(StreamRoute.active_lanes(), fn {profile, class} = pair ->
      {:ok, lane} = for_lane(profile, class)
      {pair, lane}
    end)
  end
end
