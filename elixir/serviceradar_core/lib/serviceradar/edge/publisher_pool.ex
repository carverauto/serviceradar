defmodule ServiceRadar.Edge.PublisherPool do
  @moduledoc """
  One traffic class's publisher, owning that class's in-flight window
  (unify-sweep-results-proto task 3.3(c) part 3).

  ## Why a process here, and not in parts 1 or 2

  `ResolvedPrefix` and `PublishWindow` are plain data because a lane's accounting has one owner
  and needs no concurrency. This does not: bulk, interactive and recovery publish CONCURRENTLY and
  must not be able to take capacity from one another, which means separate state with separate
  owners. That is a process, and it is the first point in this task where one is justified rather
  than assumed.

  It also makes a property observable that parts 1 and 2 could only document. In pure data an
  `{:error, _}` return exposes no replacement term, so "state unchanged after a rejected call" is
  guaranteed by immutability and untestable. Here the state lives in a process and survives the
  call, so a rejection that corrupted it WOULD be visible -- and is tested.

  ## Capacity is per class and UNBORROWABLE

  Each lane holds its own `PublishWindow`, sized by its own CONFIGURED credits -- provisional
  operational values, not a negotiated grant, since the lane-handshake grant is not frozen. A
  bulk pool at its frame or
  byte ceiling refuses; it does not consult, drain, or fall back to another class. The spec
  requires the recovery stream to have "separate unborrowable storage, PubAck, and consumer
  capacity", and borrowing in EITHER direction defeats that -- a bulk backlog must not be able to
  starve a recovery frame, and recovery must not silently consume the interactive reserve either.

  Isolation is therefore structural: there is no cross-class API. A pool cannot reach another
  pool's window because it has no reference to one.

  ## One pool per CLASS, never per scope

  The spec forbids creating a durable, connection, process, account, or physical stream per network
  scope, agent, producer assignment, run/execution, output contract, package, or logical partition.
  The pool KEY is the class alone: `start_link/1` accepts no scope, agent, or partition, so a pool
  keyed to one of those cannot be constructed.

  That is a statement about the KEY, not about the COUNT, and the two were previously conflated
  here. `start_link/1` still accepts a `:name`, so a caller can start any number of pools -- tests
  do exactly that, unregistered, to run concurrently. What bounds the count is ownership rather
  than construction: `ServiceRadar.Edge.PublisherSupervisor` starts one pool per lane under
  `via/1`, and it is the only thing in the application that starts any. A second pool for a lane
  would have to be started deliberately, by something that is not the supervision tree.

  ## What is wired, and what is NOT

  Each lane has its own NATS connection and its own window, both started by
  `ServiceRadar.Edge.PublisherSupervisor` -- NOT by `ServiceRadar.NATS.Supervisor`, which owns only
  the shared platform connection. `ServiceRadarAgentGateway.JetStreamPublisher` publishes on the
  lane's connection AND admits/settles through this window: a saturated lane refuses before any
  I/O, a durable PubAck releases the credit, and a refusal that is not proven poison leaves the
  frame outstanding for a republish.

  NOW WIRED, and this section previously said otherwise: publication is no longer one synchronous
  request per record. `ServiceRadar.Edge.PublishPipeline` runs several through this window at
  once, each worker admitting, publishing and settling in its OWN process -- which is what the
  "admit, publish and settle in the same process" rule above requires, and why the pipeline hands
  out work rather than reservations.

  The consequence for this module is that the sentence which used to sit here -- "the window
  bounds concurrent admissions but NOT concurrent publications" -- is no longer true. A worker
  holds its credits for exactly as long as its request is outstanding, so what the grant bounds is
  the number of requests on the wire.

  STILL NOT wired: nothing in the application offers to a pipeline yet. The gateway's per-lane
  session is task 3.1's, and `JetStreamPublisher.publish_record/2` has no production caller
  either, so the whole chain is exercised by tests.

  STILL NOT this module's: 3.4 owns exact-byte and retained-memory binding; 3.5 owns
  outcome-specific PubAck validation and prefix advancement. This module also does not bind byte
  credits to encoded frame size.

  """

  use GenServer

  alias ServiceRadar.Edge.PublisherLane
  alias ServiceRadar.Edge.PublishWindow

  require Logger

  # Read at COMPILE time so the values can still appear in guards. ONE list, owned by
  # PublisherLane, because a second copy here would let the pools and the connections drift:
  # a lane with a pool and no connection publishes nowhere, and a connection with no pool is
  # unbounded capacity nothing accounts for.
  @classes PublisherLane.lanes()

  # The spec's retention bound: "at most one accepting and one draining generation". DRAINING is a
  # generation this accountant still knows about but whose registrar is gone -- normally for only
  # as long as its :DOWN sits in the mailbox. Two is therefore the steady-state overlap, and a
  # THIRD is not a busier lane, it is a lost :DOWN or a registrar that outlived its subtree.
  @max_generations 2

  # How long a caller waits for the pool before revoking its admission. Deliberately explicit --
  # the GenServer default is invisible, and this value is what the cancellation protocol is built
  # around. Configurable so the revocation path can be exercised without a five-second test.
  @default_call_timeout_ms 5_000

  @doc "The traffic classes that get their own pool. Not extensible at runtime, by design."
  def classes, do: @classes

  @doc """
  Starts the pool for one class.

  Takes `:class`, `:frame_credits` and `:byte_credits` -- and deliberately nothing that would key
  a pool to a scope, agent, assignment, run, contract or partition.
  """
  def start_link(opts) do
    class = Keyword.fetch!(opts, :class)

    if class not in @classes do
      raise ArgumentError,
            "unknown traffic class #{inspect(class)}; expected one of #{inspect(@classes)}"
    end

    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, via(class)))
  end

  @doc "The registered name for a class's pool."
  def via(class) when class in @classes, do: :"edge_publisher_pool_#{class}"

  @doc """
  Admits a frame into this lane's window, or refuses.

  `key` is the PUBLICATION (`PublishWindow.key/5`) -- the authenticated slot AND the record
  identity -- never the lane sequence: one pool serves every agent and spool in its class, so a
  bare sequence aliases across them.

  A republish of the SAME record re-arms without new credits, but only once its previous attempt
  has ended; a retry offered while that attempt is still on the wire is refused
  `:attempt_in_flight`. A DIFFERENT record on that slot is a different publication and is admitted
  on its own credits -- the spec requires it to be published so EventWriter can adjudicate it.

  `ack_timeout_ms` is a TIMEOUT, not a deadline: this pool stamps the deadline when it admits, so
  time a caller spent queued here is not deducted from the PubAck interval it measures.

  A refusal is final for THIS call: it never borrows from another class, and the pool's state is
  untouched.

  ## THE CALLING PROCESS BECOMES THE ATTEMPT'S OWNER

  Taken from the call's `from`, so there is no argument in which a caller could name a different
  process. It is the ONLY process that may later end this attempt -- `settle/3`, `attempt_failed/2`
  and `rearm/3` all refuse anyone else, which is what fences a retry on the previous request
  rather than on a deadline.

  The practical constraint that follows: ADMIT, PUBLISH AND SETTLE MUST HAPPEN IN THE SAME
  PROCESS. Handing a reservation to a different process to publish leaves the admitter as the
  owner, and only the admitter can report the outcome. `JetStreamPublisher` does all three inline,
  which is why this holds today.
  """
  def admit(pool, key, bytes, ack_timeout_ms) do
    # An admission the CALLER never receives must not stay charged. GenServer.call/3 gives up
    # after its own timeout, but OTP does not cancel the queued message: the pool goes on to
    # admit, and the frame is charged for a request that was never made.
    #
    # So each admission carries a reference the caller can revoke. Message order between this
    # process and the pool is FIFO, so the cancel is handled AFTER the admission it cancels --
    # whether that admission had already been processed or was still queued.
    #
    # Cancelling is safe precisely because the caller never got the reservation, and therefore
    # never published. That is what authorises the release; the caller merely being dead does not.
    attempt_ref = make_ref()

    try do
      case GenServer.call(pool, {:admit, key, bytes, ack_timeout_ms, attempt_ref}, call_timeout()) do
        {:ok, reservation} ->
          # HANDOFF CONFIRMED. Until this arrives the pool holds the admission provisionally and
          # will revoke it if this process dies -- because nothing can have been published before
          # admit/4 returned. After it, death is conservatively charged: by then a request may be
          # on the socket.
          GenServer.cast(pool, {:confirm_admission, attempt_ref})
          {:ok, reservation}

        {:error, _reason} = error ->
          error
      end
    catch
      :exit, {:timeout, _} ->
        GenServer.cast(pool, {:cancel_admission, attempt_ref})
        {:error, :pool_timeout}

      :exit, _reason ->
        {:error, :pool_gone}
    end
  end

  @doc "Releases a frame's credits. See `PublishWindow.settle/3` -- accounting only."
  def settle(pool, reservation, outcome),
    do: GenServer.call(pool, {:settle, reservation, outcome})

  @doc """
  Ends the in-flight attempt, keeping the reservation and its credits.

  Called for a NON-terminal transport outcome. Without it the reservation stays marked in flight
  and the next retry is refused `:attempt_in_flight` forever.
  """
  def attempt_failed(pool, reservation), do: GenServer.call(pool, {:attempt_failed, reservation})

  @doc "Moves a frame's PubAck deadline without releasing its credits."
  def rearm(pool, reservation, ack_timeout_ms),
    do: GenServer.call(pool, {:rearm, reservation, ack_timeout_ms})

  @doc "The frames whose PubAck deadline has passed. Reports only."
  def expired(pool), do: GenServer.call(pool, :expired)

  @doc """
  Registers a transport generation and returns its reference.

  Called by the lane's transport runtime once its connection is up. Until one is registered this
  accountant is CLOSED: `admit/4` returns `{:error, :no_transport}` rather than handing out
  credits against transport that does not exist.

  That is the fail-closed half of the restart contract. This process outlives transport restarts
  ON PURPOSE -- that is what stops a replacement from reopening the full grant -- but the
  converse must not hold: if this process is itself replaced, its ledger is empty, and an empty
  ledger that accepts admissions is exactly the over-admission defect wearing a different hat. So
  a fresh accountant refuses everything until a transport registers, which under `:rest_for_one`
  cannot happen until the previous transport subtree has been terminated.

  The generation is a reference, not a counter: a counter restarted with this process, so a stale
  generation would compare equal to a fresh one and fencing the old would fence the new.

  ## Registration is a BOUNDED transition, and can be refused

  Three refusals, each closing a state the previous unconditional `Map.put` could reach:

    * `:dead_registrar` -- the registering process is already gone. Admitting it would make a dead
      generation `accepting`, and the `:DOWN` already in flight would then close the lane.
    * `:generation_limit` -- `@max_generations` live generations are already known. Dead ones are
      reaped first, so this is never tripped by an undelivered `:DOWN`; reaching it means a
      registrar outlived the subtree it stands for.
    * a repeat for a process already registered returns its EXISTING generation rather than
      minting a second. One registrar is one generation for its whole lifetime.

  The caller is a supervised child (`LaneTransportRuntime.Registrar`), so a refusal stops that
  child and the generation is retried under the supervisor's restart intensity -- rather than
  being admitted past the bound, or looping here.
  """
  @spec register_transport(GenServer.server(), pid()) ::
          {:ok, PublishWindow.generation()} | {:error, :dead_registrar | :generation_limit}
  def register_transport(pool, transport_pid) when is_pid(transport_pid),
    do: GenServer.call(pool, {:register_transport, transport_pid})

  @doc """
  The generations this accountant knows, and which one is accepting.

  Exposed so the spec's bound can be asserted rather than assumed: at most one accepting and one
  draining generation at a time.
  """
  def generations(pool), do: GenServer.call(pool, :generations)

  @doc "This class's current capacity, for tests and observability."
  def capacity(pool), do: GenServer.call(pool, :capacity)

  @impl true
  def init(opts) do
    {:ok, window} =
      PublishWindow.new(
        Keyword.fetch!(opts, :frame_credits),
        Keyword.fetch!(opts, :byte_credits)
      )

    {:ok,
     %{
       class: Keyword.fetch!(opts, :class),
       window: window,
       # Admissions made but NOT yet confirmed as received by their caller. Bounded by the number
       # of in-flight admit calls, not by retries: an entry leaves on confirmation, revocation, or
       # the caller's death. It previously kept one entry per admission for the life of the
       # reservation, so a record retried a hundred times carried a hundred entries.
       pending: %{},
       # The generation admissions are issued against, or nil when no transport is registered.
       # nil is the STARTING state: a fresh accountant is closed until a transport registers.
       #
       # DERIVED, never independently assigned: every mutation of `transports` goes through
       # `recompute_accepting/1`. It was previously set by hand at each site, and the two could
       # then disagree -- a late registration from an already-dead registrar overwrote a NEWER
       # accepting generation, and the dead one's :DOWN set this to nil while the live generation
       # sat in `transports` with no registrar that would ever re-register. The lane stayed closed
       # for the life of the pool. Deriving it makes that disagreement unrepresentable.
       accepting: nil,
       # generation ref => %{pid, monitor, registered_at}. Bounded by @max_generations, which is
       # the spec's "at most one accepting and one draining generation" -- enforced in
       # `handle_call({:register_transport, _}, ...)`, not merely asserted in generations/1.
       # `registered_at` is what makes "the newest live generation" well defined.
       transports: %{}
     }}
  end

  @impl true
  def handle_call({:admit, key, bytes, ack_timeout_ms, attempt_ref}, {caller, _tag}, state) do
    # The deadline is stamped HERE, not by the caller before the call. Stamped earlier, the time a
    # caller spent queued for this GenServer was silently deducted from the PubAck interval that
    # the deadline is supposed to measure -- so a contended pool shortened every ack window.
    # CLOSED until a transport registers. Admitting here would charge credits against transport
    # that does not exist, and on a fresh accountant would do it from an empty ledger.
    if state.accepting == nil do
      {:reply, {:error, :no_transport}, state}
    else
      case deadline(ack_timeout_ms) do
        {:ok, deadline_at} -> admit_reply(state, {attempt_ref, caller}, key, bytes, deadline_at)
        :error -> {:reply, {:error, :deadline}, state}
      end
    end
  end

  def handle_call({:register_transport, pid}, _from, state) do
    # REAP FIRST. A generation whose registrar has already died is draining only until its :DOWN
    # is processed, and that message may still be behind this call in the mailbox. Reaping here
    # means the bound below is measured against generations that are actually LIVE, so a
    # replacement is never refused merely because the VM has not delivered a notification yet.
    #
    # Reaping does the same thing the :DOWN would: fence the generation's attempts, keep their
    # reservations charged. It is idempotent with the :DOWN that follows, which then finds nothing.
    state = reap_dead_generations(state)

    cond do
      # A registrar that is already dead is not send capability, and accepting it is actively
      # harmful rather than merely useless: it would become `accepting`, and the :DOWN already on
      # its way would close the lane again. Refusing is also what makes `accepting` safe to
      # derive -- every generation in `transports` was alive when it was admitted.
      not Process.alive?(pid) ->
        {:reply, {:error, :dead_registrar}, state}

      # IDEMPOTENT for the same process. A registrar registers once, from `init/1`, so a repeat is
      # a retry or a duplicate rather than a second generation -- and minting a second reference
      # for one lifetime would consume the bound with a generation no death will ever clear.
      (existing = generation_of(state, pid)) != nil ->
        {:reply, {:ok, existing}, state}

      # THE BOUND. Refusing is deliberate, and the refusal reaches a supervisor rather than a
      # publisher: `LaneTransportRuntime.Registrar` stops on it, so the generation is retried
      # under the supervisor's restart intensity instead of being admitted past the bound. The
      # alternative -- evicting the oldest to make room -- would silently unmonitor a generation
      # that may still hold in-flight attempts, which is the accounting this module exists to keep.
      map_size(state.transports) >= @max_generations ->
        {:reply, {:error, :generation_limit}, state}

      true ->
        register_generation(state, pid)
    end
  end

  def handle_call(:generations, _from, state) do
    {:reply,
     %{
       accepting: state.accepting,
       known: Map.keys(state.transports),
       live: PublishWindow.live_generations(state.window)
     }, state}
  end

  # `from` is the OWNER, and it is taken from the message rather than from the request body so a
  # caller cannot name a process other than itself. Every function below that ends or extends a
  # STARTED attempt passes it, which is what makes termination the owner's to report and nobody
  # else's -- see PublishWindow's "fencing a started attempt".
  def handle_call({:attempt_failed, reservation}, {owner, _tag}, state) do
    case PublishWindow.attempt_failed(state.window, reservation, owner) do
      {:ok, window} -> {:reply, :ok, %{state | window: window}}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:settle, reservation, outcome}, {owner, _tag}, state) do
    case PublishWindow.settle(state.window, reservation, outcome, owner) do
      {:ok, window} -> {:reply, :ok, %{state | window: window}}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:rearm, reservation, ack_timeout_ms}, {owner, _tag}, state) do
    with {:ok, deadline_at} <- deadline(ack_timeout_ms),
         {:ok, window} <- PublishWindow.rearm(state.window, reservation, deadline_at, owner) do
      {:reply, :ok, %{state | window: window}}
    else
      :error -> {:reply, {:error, :deadline}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:expired, _from, state) do
    # The pool reads its OWN clock: the same one that stamped the deadlines. Taking `now` from a
    # caller let `expired(pool, nil)` raise inside the GenServer, killing the pool and, under
    # :rest_for_one, terminating and restarting the transport beneath it -- a refusable input
    # taking down the lane's send capability.
    {:reply, PublishWindow.expired(state.window, System.monotonic_time(:millisecond)), state}
  end

  def handle_call(:capacity, _from, state) do
    {:reply,
     %{
       class: state.class,
       # The connection this lane publishes on. Reported so a test can prove two pools never
       # name the same one -- shared plumbing under separate accounting is the failure this
       # increment exists to prevent, and it is invisible from the window numbers alone.
       connection: PublisherLane.connection_name(state.class),
       available_frames: PublishWindow.available_frames(state.window),
       available_bytes: PublishWindow.available_bytes(state.window),
       outstanding_frames: PublishWindow.outstanding_frames(state.window),
       outstanding_bytes: PublishWindow.outstanding_bytes(state.window)
     }, state}
  end

  defp register_generation(state, pid) do
    generation = make_ref()

    entry = %{
      pid: pid,
      monitor: Process.monitor(pid),
      # Monotonic and node-unique, for the same reason attempt tokens are: it orders generations
      # so `recompute_accepting/1` can name the NEWEST one without a counter that would restart
      # with this process.
      registered_at: System.unique_integer([:monotonic, :positive])
    }

    {:reply, {:ok, generation},
     recompute_accepting(%{state | transports: Map.put(state.transports, generation, entry)})}
  end

  defp generation_of(state, pid) do
    Enum.find_value(state.transports, fn {generation, t} ->
      if t.pid === pid, do: generation
    end)
  end

  # `accepting` is the NEWEST generation still known. Derived rather than assigned, so it cannot
  # name a generation that is not in `transports`, and cannot be nil while a live one remains --
  # the two shapes of the wedge this replaced.
  defp recompute_accepting(state) do
    accepting =
      state.transports
      |> Enum.max_by(fn {_generation, t} -> t.registered_at end, fn -> nil end)
      |> case do
        {generation, _t} -> generation
        nil -> nil
      end

    %{state | accepting: accepting}
  end

  # Every generation whose registrar is gone, fenced exactly as its :DOWN would fence it.
  defp reap_dead_generations(state) do
    state.transports
    |> Enum.reject(fn {_generation, t} -> Process.alive?(t.pid) end)
    |> Enum.reduce(state, fn {generation, t}, acc ->
      # Flushed, because the :DOWN for a generation already fenced has nothing left to do and
      # would otherwise fall through to `caller_down/2` and scan `pending` for no reason.
      Process.demonitor(t.monitor, [:flush])
      fence(acc, generation)
    end)
  end

  @impl true
  def handle_cast({:cancel_admission, attempt_ref}, state) do
    # The caller gave up before it received this reservation, so nothing was published against it.
    {:noreply, revoke(state, attempt_ref)}
  end

  def handle_cast({:confirm_admission, attempt_ref}, state) do
    # Activation and de-provisioning are one step: until the caller has the reservation in hand,
    # the attempt holds its slot but is inert -- invisible to expiry and refused by settle, rearm
    # and attempt_failed.
    case Map.fetch(state.pending, attempt_ref) do
      {:ok, %{key: key, token: token}} ->
        window =
          case PublishWindow.activate(state.window, {key, token}) do
            {:ok, w} -> w
            {:error, _} -> state.window
          end

        {:noreply, drop_pending(%{state | window: window}, attempt_ref)}

      :error ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, _pid, _reason} = down, state) do
    # TWO kinds of monitor land here and they authorise OPPOSITE things, so they are dispatched
    # by which map the monitor belongs to rather than by anything in the message.
    case Enum.find(state.transports, fn {_gen, t} -> t.monitor === monitor end) do
      {generation, _t} -> {:noreply, fence(state, generation)}
      nil -> caller_down(down, state)
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp caller_down({:DOWN, monitor, :process, _pid, _reason}, state) do
    # Only ever a PENDING admission: the monitor is dropped the moment the handoff is confirmed.
    # A caller dying before it received its reservation cannot have published, so revoking is
    # authorised here in a way that caller death in general is NOT.
    case Enum.find(state.pending, fn {_ref, p} -> p.monitor === monitor end) do
      {attempt_ref, _pending} -> {:noreply, revoke(state, attempt_ref)}
      nil -> {:noreply, state}
    end
  end

  # A transport generation is gone. Its attempts can no longer be completed on it, so they END --
  # but their reservations stay CHARGED, because transport death says nothing about whether the
  # bytes reached the broker. See PublishWindow.fence_generation/2.
  defp fence(state, generation) do
    {:ok, window, fenced} = PublishWindow.fence_generation(state.window, generation)

    if fenced > 0 do
      Logger.info(
        "edge publisher lane #{state.class}: transport generation ended with #{fenced} " <>
          "attempt(s) in flight; their reservations stay charged and may be retried without " <>
          "consuming another credit"
      )
    end

    # NOT `accepting: nil`. Closing outright was wrong whenever another generation was still
    # known: it left a live registrar in `transports` that would never register again, so the lane
    # stayed closed with send capability it refused to use. Re-deriving falls back to the newest
    # generation that remains, and to nil only when none does -- which is the fail-closed state
    # the fresh accountant already starts in.
    recompute_accepting(%{
      state
      | window: window,
        transports: Map.delete(state.transports, generation)
    })
  end

  defp admit_reply(state, {attempt_ref, caller}, key, bytes, deadline_at) do
    # WHICH KIND of admission this is decides what revoking it must do. A first admission CREATED
    # the reservation, so revoking releases the credits. A retry RE-ARMED an existing one and added
    # no credits -- the record is still unresolved and still owed a republish -- so revoking must
    # restore its no-attempt state instead. Abandoning there released a broker-ambiguous
    # reservation and let the lane publish past its grant.
    kind = if PublishWindow.outstanding?(state.window, key), do: :rearmed, else: :created

    case PublishWindow.admit(state.window, key, bytes, deadline_at, caller, state.accepting) do
      {:ok, window, {_key, token} = reservation} ->
        pending = %{key: key, token: token, kind: kind, monitor: Process.monitor(caller)}

        {:reply, {:ok, reservation},
         %{state | window: window, pending: Map.put(state.pending, attempt_ref, pending)}}

      # The rejected call returns the ORIGINAL state. This is the case immutability made
      # untestable in parts 1 and 2, and it is asserted at the process boundary now.
      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp call_timeout do
    Application.get_env(
      :serviceradar_core,
      :publisher_pool_call_timeout_ms,
      @default_call_timeout_ms
    )
  end

  defp deadline(ms) when is_integer(ms) and ms >= 0,
    do: {:ok, System.monotonic_time(:millisecond) + ms}

  defp deadline(_), do: :error

  # Undo an admission whose caller never took delivery of it.
  defp revoke(state, attempt_ref) do
    case Map.fetch(state.pending, attempt_ref) do
      {:ok, %{key: key, token: token, kind: kind}} ->
        reservation = {key, token}

        result =
          case kind do
            :created -> PublishWindow.abandon(state.window, reservation)
            :rearmed -> PublishWindow.revoke_pending(state.window, reservation)
          end

        window =
          case result do
            {:ok, w} -> w
            # Token mismatch: this attempt was already superseded, so there is nothing to undo.
            {:error, _} -> state.window
          end

        drop_pending(%{state | window: window}, attempt_ref)

      :error ->
        state
    end
  end

  defp drop_pending(state, attempt_ref) do
    case Map.pop(state.pending, attempt_ref) do
      {nil, _} ->
        state

      {%{monitor: monitor}, rest} ->
        Process.demonitor(monitor, [:flush])
        %{state | pending: rest}
    end
  end
end
