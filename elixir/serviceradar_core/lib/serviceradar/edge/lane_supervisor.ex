defmodule ServiceRadar.Edge.LaneSupervisor do
  @moduledoc """
  One traffic lane as a single restart unit: its NATS connection and its `PublisherPool`.

  ## Why the accountant is STABLE and the transport REPLACEABLE

  They were `:one_for_one` siblings under one supervisor, which quietly relaxed the bound the pool
  exists to enforce. `PublisherPool.init/1` builds an EMPTY window, so restarting only the pool
  makes the whole grant available again -- while the lane's NATS connection is untouched and the
  requests admitted under the old window are still in flight on it. Another caller can then publish
  past the grant, and the original caller, holding the dead pool's pid, exits inside its own
  `settle/3` after receiving a durable PubAck.

  `:one_for_all` was the first answer and it was the wrong one. It made the two share a restart
  boundary, which NARROWED the interval in which they could disagree without closing it --
  supervisor restarts are ordered but not instantaneous, so a publisher holding the OLD connection
  could still complete a request while the replacement pool started with its full grant. It was
  also wrong in the other direction: it emptied the ledger on every transport blip.

  The ledger is now something a restart CANNOT empty. `:rest_for_one` with the accountant FIRST
  gives the two directions their different answers -- see `init/1`, where the ordering argument is
  made against the code it governs.

  ## What that closes, and what it does not

  CLOSED: transient over-admission across a transport restart. A replacement transport inherits
  the credits the previous generation consumed rather than a fresh grant, and
  `PublishWindow.fence_generation/2` ends the dead generation's attempts while KEEPING their
  reservations charged -- because generation death proves the request cannot complete on that
  transport and proves nothing about whether the bytes reached the broker.

  ALSO CLOSED, and separately: the reporting. `JetStreamPublisher` refuses to report a publish
  durable when the accounting that authorised it did not survive -- it returns a RETRYABLE error
  instead of reporting the record delivered. Nothing at this layer republishes; there is no
  production caller, so what is established is only the RETURN VALUE. Withholding progress for
  that source sequence is the future caller's obligation.

  NOT CLOSED: an owner that dies mid-request. Fencing fires on the death of a transport
  GENERATION, not of an owner, so such a reservation stays charged with no attempt against it.
  That is deliberate -- owner death is not evidence the record went unpublished -- and bounding it
  needs evidence that the specific REQUEST terminated, which is task 3.5's correlation work.

  NOT CLOSED EITHER: this holds against the SERIAL publisher that exists today. An invariant
  exercised only serially is not an invariant under concurrency, and 3.3's asynchronous pipeline
  is what must also hold it.

  ## What this does NOT cover: an ordinary reconnect

  Stated because the first version of this text implied otherwise. The supervised child is
  `Gnat.ConnectionSupervisor`, the RECONNECT MANAGER -- not the transport socket it owns. A normal
  NATS reconnect replaces the inner connection and the wrapper never exits, so no generation ends,
  nothing is restarted, and the pool is untouched.

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

  alias ServiceRadar.Edge.LaneTransportRuntime
  alias ServiceRadar.Edge.PublisherPool

  def start_link(opts) do
    lane = Keyword.fetch!(opts, :lane)
    Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, via(lane)))
  end

  @doc "The registered name of a lane's restart unit."
  def via(lane), do: :"edge_publisher_lane_#{lane}"

  @doc """
  This lane's two children, ACCOUNTANT FIRST.

  The order is the invariant, not a style choice, because `:rest_for_one` derives its behaviour
  from it: children after the accountant are torn down when it dies, and children before it are
  not. Accountant first therefore means transport death leaves the ledger alone, while accountant
  death fences the transport before a fresh, empty ledger can exist.

  Public so both the inventory and that order can be asserted without a NATS server.
  """
  def child_specs(opts) do
    lane = Keyword.fetch!(opts, :lane)
    settings = Keyword.fetch!(opts, :connection_settings)
    backoff = Keyword.fetch!(opts, :backoff_period)
    credits = Keyword.fetch!(opts, :credits)

    [
      Supervisor.child_spec(
        {PublisherPool, [class: lane, name: PublisherPool.via(lane)] ++ credits},
        id: PublisherPool.via(lane)
      ),
      Supervisor.child_spec(
        {LaneTransportRuntime,
         lane: lane,
         connection_settings: settings,
         backoff_period: backoff,
         accountant: PublisherPool.via(lane)},
        id: LaneTransportRuntime.via(lane)
      )
    ]
  end

  @impl true
  def init(opts) do
    # :rest_for_one, and the direction matters in both senses:
    #
    #   transport dies    -> the accountant is BEFORE it, so it is untouched. Every charge
    #                        survives, and the replacement transport inherits the remaining
    #                        capacity instead of a fresh grant. That is the restart invariant.
    #   accountant dies   -> the transport is AFTER it, so it is terminated before the accountant
    #                        restarts. A fresh accountant has an empty ledger, and an empty ledger
    #                        with live send capability is the over-admission defect again; the
    #                        accountant additionally starts CLOSED, so it admits nothing until a
    #                        new generation registers.
    #
    # :one_for_all would have been wrong in the first direction (it would restart the accountant
    # on every transport blip, emptying the ledger); :one_for_one wrong in the second (an
    # accountant could restart empty alongside a live transport).
    Supervisor.init(child_specs(opts), strategy: :rest_for_one)
  end
end
