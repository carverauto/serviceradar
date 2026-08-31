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

  Accounting and in-flight request ownership therefore share a restart boundary: under
  `:one_for_all`, a crash in either child restarts both. That narrows the window in which the two
  can disagree. It does not eliminate it -- see below.

  ## This is NOT an atomic fence, and must not be read as one

  Stated because an earlier version of this text overstated it. Supervisor restarts are eventual,
  not atomic: between a pool crashing and the supervisor terminating its sibling, a publisher
  holding the OLD connection can still complete a request. The replacement pool then starts with
  its full grant while that publish is still broker-ambiguous, so the lane can briefly exceed its
  bound.

  What is closed today is the reporting: `JetStreamPublisher` refuses to report a publish durable
  when the accounting that authorised it did not survive: it returns a RETRYABLE error instead of
  reporting the record delivered. Nothing at this layer republishes -- there is no production
  caller -- so what is established is that the source sequence stays unresolved.

  What is NOT closed is the transient over-admission itself, and that obligation belongs to TASK
  3.3, which requires the hard window. It is not 3.4's (exact-byte and memory binding) nor 3.5's
  (outcome-specific PubAck validation and prefix advancement). Correlation may assist recovery,
  but it cannot by itself fence this: no PubAck cannot distinguish "never sent" from "in flight"
  or "acked but the ack was lost". Fencing on the request -- owner, start, termination -- is what
  3.3's publisher pipeline still needs.

  The conservative direction is to lose an in-flight publish rather than orphan its accounting:
  the record simply stays unresolved. Reconstructing reservations for requests whose replies may
  still arrive would need to know whether those requests completed, which nothing here can
  determine.

  ## What this does NOT cover: an ordinary reconnect

  Stated because the first version of this text implied otherwise. The supervised child is
  `Gnat.ConnectionSupervisor`, the RECONNECT MANAGER -- not the transport socket it owns. A normal
  NATS reconnect replaces the inner connection and the wrapper never exits, so `:one_for_all` does
  not fire and the pool is NOT restarted.

  That is the behaviour we want, and it is deliberate rather than incidental. A reconnect does not
  make the records go away: their reservations should stay charged, because each one is still owed
  a republish on the same slot when one is offered. What a reconnect does is fail the requests
  that were in flight,
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
