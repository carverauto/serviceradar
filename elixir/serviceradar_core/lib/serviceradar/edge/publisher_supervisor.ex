defmodule ServiceRadar.Edge.PublisherSupervisor do
  @moduledoc """
  Owns the edge publisher pools: exactly one per `PublisherLane.lanes/0`, and nothing else.

  ## Why this exists rather than starting pools on demand

  `PublisherPool` is a process, and a process nobody supervises is a window nobody owns. Without
  this, the pools existed only in tests: the lane connections were started, the accounting code
  was written, and at runtime every publish still shared one mailbox with no frame or byte bound
  in front of it. The gap was invisible from the pool's own tests, because a test starts its own
  pool.

  ## The ownership boundary, stated exactly

  This supervisor's children ARE the production topology: three pools, registered under
  `PublisherPool.via/1`, one per lane. `child_specs/1` is public so that inventory can be
  asserted without starting NATS.

  What this does NOT claim is that a pool is unconstructable elsewhere. `PublisherPool.start_link/1`
  still accepts a `:name`, and tests use unregistered pools to run concurrently. The bound that
  holds is about the SUPERVISED topology -- the application starts these three and no others --
  not about what a caller could construct in principle. The earlier framing of this as
  "structural cardinality" overstated it: a closed lane list bounds the declared NAMES, which is
  not the same as bounding how many windows exist.

  ## Credits are PROVISIONAL

  Task 1.7-e has not frozen the lane-handshake admission bounds, so the defaults below are
  operational placeholders, not the negotiated values, and they are configurable precisely so
  nothing here reads as a frozen constant. When 1.7-e lands, the grant supplies them and these
  defaults should disappear rather than be tuned.
  """

  use Supervisor

  alias ServiceRadar.Edge.PublisherLane
  alias ServiceRadar.Edge.PublisherPool

  # Provisional. See the moduledoc: NOT the frozen 1.7-e bounds.
  @default_frame_credits 64
  @default_byte_credits 64 * 1024 * 1024

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  One pool child spec per lane.

  Public so the inventory -- the count, the lane of each child, and the registered name each will
  claim -- can be asserted directly. Testing the pools individually cannot see a supervisor that
  starts two of them, or one that starts three pools all registering the same name.
  """
  def child_specs(opts \\ []) do
    Enum.map(PublisherLane.lanes(), fn lane ->
      Supervisor.child_spec(
        {PublisherPool,
         class: lane,
         frame_credits: credits(opts, :frame_credits, @default_frame_credits),
         byte_credits: credits(opts, :byte_credits, @default_byte_credits),
         name: PublisherPool.via(lane)},
        # PublisherPool's default child id is the MODULE, so three of them under one supervisor
        # collide and only the first starts. The registered name is unique per lane already.
        id: PublisherPool.via(lane)
      )
    end)
  end

  @impl true
  def init(opts) do
    Supervisor.init(child_specs(opts), strategy: :one_for_one)
  end

  defp credits(opts, key, default), do: Keyword.get(opts, key, default)
end
