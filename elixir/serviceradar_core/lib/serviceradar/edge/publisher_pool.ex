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
    GenServer.call(pool, {:admit, key, bytes, ack_timeout_ms})
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
       # Who holds each reservation, so a caller that dies does not strand its credits. The case
       # that motivates this is a TIMEOUT rather than a crash: GenServer.call/3 exits the caller
       # when it gives up, and OTP does not cancel the queued message -- so this pool can admit a
       # frame for a caller that is already gone, charging the window for a request nobody will
       # ever make.
       owner_of: %{},
       monitors: %{}
     }}
  end

  @impl true
  def handle_call({:admit, key, bytes, ack_timeout_ms}, {caller, _tag}, state) do
    # The deadline is stamped HERE, not by the caller before the call. Stamped earlier, the time a
    # caller spent queued for this GenServer was silently deducted from the PubAck interval that
    # the deadline is supposed to measure -- so a contended pool shortened every ack window.
    case deadline(ack_timeout_ms) do
      {:ok, deadline_at} -> admit_reply(state, caller, key, bytes, deadline_at)
      :error -> {:reply, {:error, :deadline}, state}
    end
  end

  def handle_call({:attempt_failed, reservation}, _from, state) do
    case PublishWindow.attempt_failed(state.window, reservation) do
      {:ok, window} -> {:reply, :ok, %{state | window: window}}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:settle, {key, _token} = reservation, outcome}, _from, state) do
    case PublishWindow.settle(state.window, reservation, outcome) do
      {:ok, window} -> {:reply, :ok, forget_owner(%{state | window: window}, key)}
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
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    # Everything that caller held is released. Nobody else can settle or retry it: the reservation
    # handle lived in that process, and a new caller for the same publication will admit afresh.
    # This is the path that recovers a frame charged for a caller that had already given up --
    # GenServer.call/3's timeout exits the caller, but OTP still delivers the queued admission.
    {mine, theirs} = Enum.split_with(state.owner_of, fn {_key, owner} -> owner === pid end)

    window =
      Enum.reduce(mine, state.window, fn {key, _owner}, w ->
        case PublishWindow.abandon(w, key) do
          {:ok, w2} -> w2
          {:error, _} -> w
        end
      end)

    {:noreply,
     %{
       state
       | window: window,
         owner_of: Map.new(theirs),
         monitors: Map.delete(state.monitors, pid)
     }}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp admit_reply(state, caller, key, bytes, deadline_at) do
    case PublishWindow.admit(state.window, key, bytes, deadline_at) do
      {:ok, window, reservation} ->
        {:reply, {:ok, reservation}, remember_owner(%{state | window: window}, caller, key)}

      # The rejected call returns the ORIGINAL state. This is the case immutability made
      # untestable in parts 1 and 2, and it is asserted at the process boundary now.
      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp deadline(ms) when is_integer(ms) and ms >= 0,
    do: {:ok, System.monotonic_time(:millisecond) + ms}

  defp deadline(_), do: :error

  defp remember_owner(state, caller, key) do
    monitors =
      if Map.has_key?(state.monitors, caller) do
        state.monitors
      else
        Map.put(state.monitors, caller, Process.monitor(caller))
      end

    %{state | owner_of: Map.put(state.owner_of, key, caller), monitors: monitors}
  end

  defp forget_owner(state, key) do
    owner_of = Map.delete(state.owner_of, key)
    owner = Map.get(state.owner_of, key)

    # Stop monitoring a caller once it holds nothing.
    monitors =
      if owner && not Enum.any?(owner_of, fn {_k, pid} -> pid === owner end) do
        case Map.pop(state.monitors, owner) do
          {nil, m} -> m
          {ref, m} -> Process.demonitor(ref, [:flush]) && m
        end
      else
        state.monitors
      end

    %{state | owner_of: owner_of, monitors: monitors}
  end
end
