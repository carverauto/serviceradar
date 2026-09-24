defmodule ServiceRadar.Edge.LaneTransportRuntime do
  @moduledoc """
  One GENERATION of a lane's send capability: its NATS connection, supervised as a unit, and
  registered with the lane's accountant so the accountant can tell when that generation dies.

  ## Why this exists as its own supervisor

  Accounting and transport used to share a restart unit (`:one_for_all` over connection + pool).
  That coupling was chosen to stop the pool restarting alone with an empty window -- which would
  have reopened the full grant while requests admitted under the old window were still in flight.
  It narrowed the race without closing it, because supervisor restarts are ordered but not
  instantaneous.

  Splitting the lane into a STABLE accountant and a REPLACEABLE transport closes it from the
  other side: the ledger is no longer something a restart can empty. A replacement transport
  inherits the credits the previous one consumed, so old and replacement requests together cannot
  exceed the lane grant.

  ## The two directions are deliberately NOT symmetric

  Transport dies -> the accountant survives, keeps every charge, and fences the dead generation's
  attempts (see `PublishWindow.fence_generation/2`). Reservations stay charged; only a validated
  PubAck releases credits.

  Accountant dies -> under `LaneSupervisor`'s `:rest_for_one` this whole subtree is terminated
  first and restarted after it. That ordering is the point. A fresh accountant has an EMPTY
  ledger, and an empty ledger that accepts admissions is the over-admission defect wearing a
  different hat, so the accountant starts CLOSED and only opens when a transport registers --
  which cannot happen until the previous send capability has been terminated.

  ## What registration proves, and what it does not

  The accountant binds to this process's LIFETIME, not to anything it can do. Its death is the
  signal that a generation can no longer complete a request. It is NOT evidence about whether any
  particular record reached the broker: a connection can die after the bytes are sent and before
  any PubAck arrives, which is exactly why fencing ends attempts without releasing reservations.

  ## What this does NOT cover: an ordinary reconnect

  The supervised child is `Gnat.ConnectionSupervisor`, the RECONNECT MANAGER -- not the socket it
  owns. A normal NATS reconnect replaces the inner connection and this process never exits, so no
  generation ends and no fencing happens.

  That is deliberate. A reconnect does not make the records go away: their reservations should
  stay charged, because each is still owed a republish on the same slot. What a reconnect does is
  fail the in-flight requests, and the publisher reports each with `attempt_failed/3` -- keeping
  the credits, ending the attempt, letting the retry re-admit.

  So a "generation" here is the lifetime of the reconnect manager, not of a socket. Tracking
  socket generations would end attempts on every transient blip, which is both noisier and no
  safer: the publisher already reports those failures itself, with the owner authority that
  fencing deliberately lacks.
  """

  use Supervisor

  alias ServiceRadar.Edge.PublisherLane
  alias ServiceRadar.Edge.PublisherPool
  alias ServiceRadar.NATS.Supervisor, as: NATSSupervisor

  def start_link(opts) do
    lane = Keyword.fetch!(opts, :lane)
    Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, via(lane)))
  end

  @doc "The registered name of a lane's transport runtime."
  def via(lane), do: :"edge_lane_transport_#{lane}"

  @doc """
  This generation's children: the lane connection, then the registrar that announces it.

  Public so the inventory and ORDER can be asserted without a NATS server. The registrar is LAST
  on purpose -- registering a generation before its connection exists would open the accountant
  against transport that is not there yet.
  """
  def child_specs(opts) do
    lane = Keyword.fetch!(opts, :lane)
    settings = Keyword.fetch!(opts, :connection_settings)
    backoff = Keyword.fetch!(opts, :backoff_period)
    accountant = Keyword.get(opts, :accountant, PublisherPool.via(lane))

    NATSSupervisor.child_specs([PublisherLane.connection_name(lane)], settings, backoff) ++
      [
        Supervisor.child_spec(
          {__MODULE__.Registrar, lane: lane, accountant: accountant},
          id: {__MODULE__.Registrar, lane}
        )
      ]
  end

  @impl true
  def init(opts) do
    # :one_for_all WITHIN the generation. If the connection dies, this whole generation is
    # replaced -- including its registration -- rather than leaving a registrar advertising send
    # capability that no longer exists.
    Supervisor.init(child_specs(opts), strategy: :one_for_all)
  end

  defmodule Registrar do
    @moduledoc """
    Registers this transport generation with the lane's accountant, and IS the thing the
    accountant monitors.

    A process rather than a call from the supervisor, because the accountant needs something whose
    death means "this generation is gone". A supervisor's own pid would work only until someone
    restructured the tree; a dedicated child makes the lifetime being tracked explicit and gives
    the accountant a monitor target that cannot outlive the generation it stands for.

    It holds no state beyond its lane and does no work after registering. That is intentional: any
    work here would be work that could crash and take a live generation down with it.
    """

    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(opts) do
      lane = Keyword.fetch!(opts, :lane)
      accountant = Keyword.fetch!(opts, :accountant)

      # Registered from init/1 so the generation is live before the supervisor reports started,
      # and therefore before anything can publish on it.
      case PublisherPool.register_transport(accountant, self()) do
        {:ok, generation} ->
          {:ok, %{lane: lane, accountant: accountant, generation: generation}}

        # A REFUSAL, not a crash to be pattern-matched into a `badmatch`. The accountant bounds how
        # many generations it will track, so refusing is a legitimate answer and the supervisor is
        # the right thing to receive it: stopping here retries this generation under the restart
        # intensity, and if the condition persists the whole transport subtree gives up rather than
        # advertising send capability the accountant will not admit against.
        {:error, reason} ->
          {:stop, {:transport_registration_refused, reason}}
      end
    end

    @doc "This generation's reference, for tests and observability."
    def generation(pid), do: GenServer.call(pid, :generation)

    @impl true
    def handle_call(:generation, _from, state), do: {:reply, state.generation, state}
  end
end
