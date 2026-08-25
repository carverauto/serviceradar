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

  Each class holds its own `PublishWindow`, sized by its own grant. A bulk pool at its frame or
  byte ceiling refuses; it does not consult, drain, or fall back to another class. The spec
  requires the recovery stream to have "separate unborrowable storage, PubAck, and consumer
  capacity", and borrowing in EITHER direction defeats that -- a bulk backlog must not be able to
  starve a recovery frame, and recovery must not silently consume the interactive reserve either.

  Isolation is therefore structural: there is no cross-class API. A pool cannot reach another
  pool's window because it has no reference to one.

  ## One pool per CLASS, never per scope

  The spec forbids creating a durable, connection, process, account, or physical stream per network
  scope, agent, producer assignment, run/execution, output contract, package, or logical partition.
  The pool key is the traffic class alone, and `start_link/1` takes no scope, agent, or partition --
  a per-scope pool is unrepresentable rather than merely discouraged.

  ## NOT YET WIRED, and not claimed

  This owns the window and the admission decision. It does NOT hold a NATS connection: the runtime
  has ONE connection today (`:serviceradar_nats`, a single `Gnat.ConnectionSupervisor`), and
  `Connection.request/3` takes no connection name, so separately bounded publisher CONNECTIONS are
  a further increment that changes shared supervision. Nor does it publish, settle from real
  PubAcks, or bind bytes to encoded frame size -- those remain owed by tasks 3.4 and 3.5 with the
  publisher integration.

  What is real here is the ownership boundary and the isolation between classes.
  """

  use GenServer

  alias ServiceRadar.Edge.PublishWindow

  @classes [:bulk, :interactive, :recovery]

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
  Admits a frame into this class's window, or refuses.

  A refusal is final for THIS call: it never borrows from another class, and the pool's state is
  untouched.
  """
  def admit(pool, seq, bytes, deadline_at) do
    GenServer.call(pool, {:admit, seq, bytes, deadline_at})
  end

  @doc "Releases a frame's credits. See `PublishWindow.settle/3` -- accounting only."
  def settle(pool, seq, outcome), do: GenServer.call(pool, {:settle, seq, outcome})

  @doc "Moves a frame's PubAck deadline without releasing its credits."
  def rearm(pool, seq, deadline_at), do: GenServer.call(pool, {:rearm, seq, deadline_at})

  @doc "The frames whose PubAck deadline has passed. Reports only."
  def expired(pool, now), do: GenServer.call(pool, {:expired, now})

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
  def handle_call({:admit, seq, bytes, deadline_at}, _from, state) do
    case PublishWindow.admit(state.window, seq, bytes, deadline_at) do
      {:ok, window} -> {:reply, :ok, %{state | window: window}}
      # The rejected call returns the ORIGINAL state. This is the case immutability made
      # untestable in parts 1 and 2, and it is asserted at the process boundary now.
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:settle, seq, outcome}, _from, state) do
    case PublishWindow.settle(state.window, seq, outcome) do
      {:ok, window} -> {:reply, :ok, %{state | window: window}}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:rearm, seq, deadline_at}, _from, state) do
    case PublishWindow.rearm(state.window, seq, deadline_at) do
      {:ok, window} -> {:reply, :ok, %{state | window: window}}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:expired, now}, _from, state) do
    {:reply, PublishWindow.expired(state.window, now), state}
  end

  def handle_call(:capacity, _from, state) do
    {:reply,
     %{
       class: state.class,
       available_frames: PublishWindow.available_frames(state.window),
       available_bytes: PublishWindow.available_bytes(state.window),
       outstanding_frames: PublishWindow.outstanding_frames(state.window),
       outstanding_bytes: PublishWindow.outstanding_bytes(state.window)
     }, state}
  end
end
