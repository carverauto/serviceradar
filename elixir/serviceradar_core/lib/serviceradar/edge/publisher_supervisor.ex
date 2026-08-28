defmodule ServiceRadar.Edge.PublisherSupervisor do
  @moduledoc """
  Owns the edge publisher lanes: for each `PublisherLane.lanes/0`, the NATS connection it
  publishes on AND the `PublisherPool` that bounds it.

  ## Why both halves are here

  They were briefly split -- connections under `ServiceRadar.NATS.Supervisor`, pools here -- and
  the split was wrong in a way that shipped: every process enabling NATS (core and web-ng, and
  core's Helm chart enables it) opened three lane sockets it had no pool for and never published
  on, while only the gateway started pools. "One connection per lane, owned with its window" was
  true of the gateway and false everywhere else.

  Starting both from one supervisor makes the pairing structural: a lane cannot have a socket
  without a window, or a window without a socket, because the same list builds both. Connections
  are started BEFORE pools so a lane's transport exists before anything admits against it.

  ## The ownership boundary, stated exactly

  These children ARE the production topology. `child_specs/1` is public so the inventory can be
  asserted without a NATS server.

  What this does NOT claim is that a pool is unconstructable elsewhere. `PublisherPool.start_link/1`
  still accepts a `:name`, and tests use unregistered pools to run concurrently. The bound that
  holds is about the SUPERVISED topology -- the application starts these and no others -- not
  about what a caller could construct in principle.

  ## Credits

  Provisional: the lane-handshake grant is not frozen, so these are operational defaults rather
  than negotiated values. They are read from application config so a deployment can change them
  without a release:

      config :serviceradar_core, ServiceRadar.Edge.PublisherSupervisor,
        frame_credits: 64,
        byte_credits: 67_108_864,
        lane_credits: %{recovery: [frame_credits: 16]}

  `opts` beats `lane_credits`, which beats the global keys, which beat the defaults below. Calling
  them "configurable" while the only caller passed nothing was the earlier mistake: the gateway
  started a bare supervisor, so every deployment got the hard-coded values with no way to change
  them.
  """

  use Supervisor

  alias ServiceRadar.Edge.PublisherLane
  alias ServiceRadar.Edge.PublisherPool
  alias ServiceRadar.NATS.Supervisor, as: NATSSupervisor

  require Logger

  # Provisional. See the moduledoc: NOT the frozen handshake bounds.
  @default_frame_credits 64
  @default_byte_credits 64 * 1024 * 1024

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "The credits a lane starts with, after opts -> lane_credits -> global -> default."
  def credits_for(lane, opts \\ []) do
    config = Application.get_env(:serviceradar_core, __MODULE__, [])
    lane_config = config |> Keyword.get(:lane_credits, %{}) |> Map.get(lane, [])

    [
      frame_credits: pick(:frame_credits, opts, lane_config, config, @default_frame_credits),
      byte_credits: pick(:byte_credits, opts, lane_config, config, @default_byte_credits)
    ]
  end

  @doc """
  Connection children, one per lane.

  Built from `NATSSupervisor.child_specs/3` with the SAME settings the shared connection uses --
  host, auth, creds and TLS belong to the deployment, not to a lane.
  """
  def connection_child_specs do
    case NATSSupervisor.connection_settings() do
      {:ok, settings, backoff} ->
        NATSSupervisor.child_specs(lane_connection_names(), settings, backoff)

      {:error, reason} ->
        Logger.error("edge publisher connections unavailable: #{inspect(reason)}")
        []
    end
  end

  @doc "Pool children, one per lane, registered under `PublisherPool.via/1`."
  def pool_child_specs(opts \\ []) do
    Enum.map(PublisherLane.lanes(), fn lane ->
      Supervisor.child_spec(
        {PublisherPool, [class: lane, name: PublisherPool.via(lane)] ++ credits_for(lane, opts)},
        # PublisherPool's default child id is the MODULE, so three of them collide and only the
        # first starts. The registered name is unique per lane already.
        id: PublisherPool.via(lane)
      )
    end)
  end

  @doc "Every child: each lane's connection first, then each lane's pool."
  def child_specs(opts \\ []), do: connection_child_specs() ++ pool_child_specs(opts)

  @doc "The lane connection names this supervisor owns."
  def lane_connection_names, do: Enum.map(PublisherLane.lanes(), &PublisherLane.connection_name/1)

  @impl true
  def init(opts) do
    Supervisor.init(child_specs(opts), strategy: :one_for_one)
  end

  defp pick(key, opts, lane_config, config, default) do
    Keyword.get(opts, key) || Keyword.get(lane_config, key) || Keyword.get(config, key) || default
  end
end
