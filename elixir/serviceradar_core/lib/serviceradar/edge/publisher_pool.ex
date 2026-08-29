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
  may be outstanding at once, which is a real bound across concurrent callers, but the asynchronous
  pipelining and the PubAck correlation that make out-of-order settlement possible are tasks 3.4
  and 3.5. This module also does not bind byte credits to encoded frame size.

  """

  use GenServer

  alias ServiceRadar.Edge.PublisherLane
  alias ServiceRadar.Edge.PublishWindow

  # Read at COMPILE time so the values can still appear in guards. ONE list, owned by
  # PublisherLane, because a second copy here would let the pools and the connections drift:
  # a lane with a pool and no connection publishes nowhere, and a connection with no pool is
  # unbounded capacity nothing accounts for.
  @classes PublisherLane.lanes()

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

  `key` is the COMPLETE authenticated delivery slot (`PublishWindow.key/4`), never the lane
  sequence: one pool serves every agent and spool in its class, so a bare sequence aliases across
  them. `fingerprint` identifies the publication, so a republish of the SAME record re-arms
  without new credits while a DIFFERENT record on that slot is refused `:slot_conflict`.

  A refusal is final for THIS call: it never borrows from another class, and the pool's state is
  untouched.
  """
  def admit(pool, key, bytes, ack_timeout_ms) do
    GenServer.call(pool, {:admit, key, bytes, ack_timeout_ms})
  end

  @doc "Releases a frame's credits. See `PublishWindow.settle/3` -- accounting only."
  def settle(pool, reservation, outcome),
    do: GenServer.call(pool, {:settle, reservation, outcome})

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

    {:ok, %{class: Keyword.fetch!(opts, :class), window: window}}
  end

  @impl true
  def handle_call({:admit, key, bytes, ack_timeout_ms}, _from, state) do
    # The deadline is stamped HERE, not by the caller before the call. Stamped earlier, the time a
    # caller spent queued for this GenServer was silently deducted from the PubAck interval that
    # the deadline is supposed to measure -- so a contended pool shortened every ack window.
    case deadline(ack_timeout_ms) do
      {:ok, deadline_at} -> admit_reply(state, key, bytes, deadline_at)
      :error -> {:reply, {:error, :deadline}, state}
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

  defp admit_reply(state, key, bytes, deadline_at) do
    case PublishWindow.admit(state.window, key, bytes, deadline_at) do
      {:ok, window, reservation} ->
        {:reply, {:ok, reservation}, %{state | window: window}}

      # The rejected call returns the ORIGINAL state. This is the case immutability made
      # untestable in parts 1 and 2, and it is asserted at the process boundary now.
      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp deadline(ms) when is_integer(ms) and ms >= 0,
    do: {:ok, System.monotonic_time(:millisecond) + ms}

  defp deadline(_), do: :error
end
