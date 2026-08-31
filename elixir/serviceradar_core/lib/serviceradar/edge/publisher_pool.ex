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

  NOT wired: publication is still one synchronous request per record. The window bounds how many
  may be ADMITTED at once, which bounds concurrent admissions but NOT concurrent publications --
  see `PublishWindow`'s "what this does not yet bound" -- and the asynchronous
  pipelining that would make out-of-order settlement possible is also TASK 3.3's -- along with the
  hard window itself and the recording of out-of-order PubAcks. 3.4 owns exact-byte and retained-
  memory binding; 3.5 owns outcome-specific PubAck validation and prefix advancement. This module also does not bind byte credits to encoded frame size.

  """

  use GenServer

  alias ServiceRadar.Edge.PublisherLane
  alias ServiceRadar.Edge.PublishWindow

  # Read at COMPILE time so the values can still appear in guards. ONE list, owned by
  # PublisherLane, because a second copy here would let the pools and the connections drift:
  # a lane with a pool and no connection publishes nowhere, and a connection with no pool is
  # unbounded capacity nothing accounts for.
  @classes PublisherLane.lanes()

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
       pending: %{}
     }}
  end

  @impl true
  def handle_call({:admit, key, bytes, ack_timeout_ms, attempt_ref}, {caller, _tag}, state) do
    # The deadline is stamped HERE, not by the caller before the call. Stamped earlier, the time a
    # caller spent queued for this GenServer was silently deducted from the PubAck interval that
    # the deadline is supposed to measure -- so a contended pool shortened every ack window.
    case deadline(ack_timeout_ms) do
      {:ok, deadline_at} -> admit_reply(state, {attempt_ref, caller}, key, bytes, deadline_at)
      :error -> {:reply, {:error, :deadline}, state}
    end
  end

  def handle_call({:attempt_failed, reservation}, _from, state) do
    case PublishWindow.attempt_failed(state.window, reservation) do
      {:ok, window} -> {:reply, :ok, %{state | window: window}}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:settle, reservation, outcome}, _from, state) do
    case PublishWindow.settle(state.window, reservation, outcome) do
      {:ok, window} -> {:reply, :ok, %{state | window: window}}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:rearm, reservation, ack_timeout_ms}, _from, state) do
    with {:ok, deadline_at} <- deadline(ack_timeout_ms),
         {:ok, window} <- PublishWindow.rearm(state.window, reservation, deadline_at) do
      {:reply, :ok, %{state | window: window}}
    else
      :error -> {:reply, {:error, :deadline}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:expired, _from, state) do
    # The pool reads its OWN clock: the same one that stamped the deadlines. Taking `now` from a
    # caller let `expired(pool, nil)` raise inside the GenServer, killing the pool and, under
    # :one_for_all, restarting the whole lane -- a refusable input crashing the transport.
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
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    # Only ever a PENDING admission: the monitor is dropped the moment the handoff is confirmed.
    # A caller dying before it received its reservation cannot have published, so revoking is
    # authorised here in a way that caller death in general is NOT.
    case Enum.find(state.pending, fn {_ref, p} -> p.monitor === monitor end) do
      {attempt_ref, _pending} -> {:noreply, revoke(state, attempt_ref)}
      nil -> {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp admit_reply(state, {attempt_ref, caller}, key, bytes, deadline_at) do
    # WHICH KIND of admission this is decides what revoking it must do. A first admission CREATED
    # the reservation, so revoking releases the credits. A retry RE-ARMED an existing one and added
    # no credits -- the record is still unresolved and still owed a republish -- so revoking must
    # restore its no-attempt state instead. Abandoning there released a broker-ambiguous
    # reservation and let the lane publish past its grant.
    kind = if PublishWindow.outstanding?(state.window, key), do: :rearmed, else: :created

    case PublishWindow.admit(state.window, key, bytes, deadline_at) do
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
