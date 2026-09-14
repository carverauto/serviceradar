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
  instead of reporting the record delivered. Nothing at this layer republishes: `PublishPipeline`
  records that error REJECTED_RETRYABLE, which caps the lane's prefix, and
  `ServiceRadarAgentGateway.EdgeRecordIngestServer` withholds the ack for it, so the agent's own
  deadline drives the retry.

  NOT CLOSED: an owner that dies mid-request. Fencing fires on the death of a transport
  GENERATION, not of an owner, so such a reservation stays charged with no attempt against it.
  That is deliberate -- owner death is not evidence the record went unpublished -- and bounding it
  needs evidence that the specific REQUEST terminated, which is task 3.5's correlation work.

  UNDER CONCURRENCY TOO: `PublishPipeline`, started last in this unit when a `:publisher` is
  supplied, runs several publishes through one window at once, and its tests exercise the restart
  invariant with four requests on the wire when the generation dies.

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
  alias ServiceRadar.Edge.PublishPipeline

  def start_link(opts) do
    lane = Keyword.fetch!(opts, :lane)
    Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, via(lane)))
  end

  @doc "The registered name of a lane's restart unit."
  def via(lane), do: :"edge_publisher_lane_#{lane}"

  @doc "The registered name of the task supervisor a lane's publish workers run under."
  def task_supervisor(lane), do: :"edge_publish_tasks_#{lane}"

  @doc """
  This lane's children, ACCOUNTANT FIRST: the accountant, then -- when a `:publisher` is supplied
  -- the task supervisor its publish workers run under, then the transport, and the
  `PublishPipeline` LAST.

  The order is the invariant, not a style choice, because `:rest_for_one` derives its behaviour
  from it: children after the accountant are torn down when it dies, and children before it are
  not. Accountant first therefore means transport death leaves the ledger alone, while accountant
  death fences the transport before a fresh, empty ledger can exist.

  `:pipeline` carries the pipeline's `:max_inflight`, `:max_queue` and `:max_lanes`, as
  `ServiceRadar.Edge.PublisherSupervisor.pipeline_for/2` resolves them. Without it the pipeline
  runs at its own defaults.

  Public so both the inventory and that order can be asserted without a NATS server.
  """
  def child_specs(opts) do
    lane = Keyword.fetch!(opts, :lane)
    settings = Keyword.fetch!(opts, :connection_settings)
    backoff = Keyword.fetch!(opts, :backoff_period)
    credits = Keyword.fetch!(opts, :credits)
    bounds = Keyword.get(opts, :pipeline, [])

    accountant =
      Supervisor.child_spec(
        {PublisherPool, [class: lane, name: PublisherPool.via(lane)] ++ credits},
        id: PublisherPool.via(lane)
      )

    transport =
      Supervisor.child_spec(
        {LaneTransportRuntime,
         lane: lane,
         connection_settings: settings,
         backoff_period: backoff,
         accountant: PublisherPool.via(lane)},
        id: LaneTransportRuntime.via(lane)
      )

    case Keyword.get(opts, :publisher) do
      # Only with a publisher. `JetStreamPublisher` lives in the gateway, which depends on this
      # application rather than the reverse, so only the gateway can hand one in -- and a pipeline
      # nothing could publish through would be a process with no runtime reason.
      nil ->
        [accountant, transport]

      publisher when is_function(publisher, 2) ->
        [
          accountant,
          Supervisor.child_spec({Task.Supervisor, name: task_supervisor(lane)},
            id: task_supervisor(lane)
          ),
          transport,
          Supervisor.child_spec({PublishPipeline, pipeline_opts(lane, publisher, bounds)},
            id: PublishPipeline.via(lane)
          )
        ]
    end
  end

  defp pipeline_opts(lane, publisher, bounds) do
    [
      class: lane,
      # The accountant's NAME, not a pid: a worker resolves it when it admits, and a pid captured
      # here would outlive nothing, since accountant death restarts this whole unit.
      pool: PublisherPool.via(lane),
      publisher: publisher,
      task_supervisor: task_supervisor(lane),
      name: PublishPipeline.via(lane)
    ] ++ bounds
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
    #   pipeline dies     -> it is LAST, so nothing else restarts. It loses only its trackers; the
    #                        ingest server sees it go and ends each stream, and every agent
    #                        re-opens at its own first_unresolved_sequence.
    #
    # Transport death also takes the pipeline after it: the prefixes waiting on requests in flight
    # on a dead transport do not outlive it.
    #
    # It does NOT take the task supervisor, which is BEFORE it. A publish worker is not part of a
    # transport generation: it is the OWNER of its attempt, and the accountant fences a dead
    # generation's attempts itself, never on an owner's death. Killed with the transport, no request
    # could ever still be running beside the replacement generation -- the very overlap the restart
    # invariant is about. The workers run on until their requests return, and exit. The task
    # supervisor's own death takes the transport after it, so the generation its workers' attempts
    # were issued on is fenced.
    #
    # :one_for_all would have been wrong in the first direction (it would restart the accountant
    # on every transport blip, emptying the ledger); :one_for_one wrong in the second (an
    # accountant could restart empty alongside a live transport).
    Supervisor.init(child_specs(opts), strategy: :rest_for_one)
  end
end
