defmodule ServiceRadar.Edge.LaneSupervisor do
  @moduledoc """
  One traffic lane as a single restart unit: its NATS connection and its `PublisherPool`.

  ## Why `:one_for_all`, and why they must not be siblings

  They were `:one_for_one` siblings under one supervisor, which quietly relaxed the bound the pool
  exists to enforce. `PublisherPool.init/1` builds an EMPTY window, so restarting only the pool
  makes the whole grant available again -- while the lane's NATS connection is untouched and the
  requests admitted under the old window are still in flight on it. Another caller can then publish
  past the grant, and the original caller, holding the dead pool's pid, exits inside its own
  `settle/3` after receiving a durable PubAck.

  Accounting and in-flight request ownership therefore need a COMMON restart boundary. Under
  `:one_for_all` a pool crash also restarts the connection, so the requests whose reservations were
  just discarded are dropped with it: the window and the socket can never disagree about what is
  outstanding. The reverse holds too -- a connection crash clears the reservations for requests
  that died with it, instead of leaving them charged until their deadlines.

  This is the conservative direction. A restart drops in-flight publishes rather than orphaning
  them, and the agent republishes on the same slot; the alternative -- reconstructing reservations
  for requests whose replies may still arrive -- needs the PubAck correlation that tasks 3.4 and
  3.5 own.

  ## What this does NOT cover: an ordinary reconnect

  Stated because the first version of this text implied otherwise. The supervised child is
  `Gnat.ConnectionSupervisor`, the RECONNECT MANAGER -- not the transport socket it owns. A normal
  NATS reconnect replaces the inner connection and the wrapper never exits, so `:one_for_all` does
  not fire and the pool is NOT restarted.

  That is the behaviour we want, and it is deliberate rather than incidental. A reconnect does not
  make the records go away: their reservations should stay charged, because each one is still owed
  a republish on the same slot. What a reconnect does is fail the requests that were in flight,
  and the publisher reports each of those with `PublishWindow.attempt_failed/2` -- keeping the
  credits, ending the attempt, and letting the retry re-admit.

  So the restart boundary covers PROCESS DEATH of either child, which is where accounting and
  in-flight ownership could otherwise disagree. Transport generations within a living reconnect
  manager are not tracked here, and reservations deliberately survive them.
  """

  use Supervisor

  alias ServiceRadar.Edge.PublisherLane
  alias ServiceRadar.Edge.PublisherPool
  alias ServiceRadar.NATS.Supervisor, as: NATSSupervisor

  def start_link(opts) do
    lane = Keyword.fetch!(opts, :lane)
    Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, via(lane)))
  end

  @doc "The registered name of a lane's restart unit."
  def via(lane), do: :"edge_publisher_lane_#{lane}"

  @doc """
  This lane's two children, connection first.

  Public so the pairing and the ORDER can be asserted without a NATS server: the transport has to
  exist before the window admits anything against it.
  """
  def child_specs(opts) do
    lane = Keyword.fetch!(opts, :lane)
    settings = Keyword.fetch!(opts, :connection_settings)
    backoff = Keyword.fetch!(opts, :backoff_period)
    credits = Keyword.fetch!(opts, :credits)

    NATSSupervisor.child_specs([PublisherLane.connection_name(lane)], settings, backoff) ++
      [
        Supervisor.child_spec(
          {PublisherPool, [class: lane, name: PublisherPool.via(lane)] ++ credits},
          id: PublisherPool.via(lane)
        )
      ]
  end

  @impl true
  def init(opts) do
    Supervisor.init(child_specs(opts), strategy: :one_for_all)
  end
end
