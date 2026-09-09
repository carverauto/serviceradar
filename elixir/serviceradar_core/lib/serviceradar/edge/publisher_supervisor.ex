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
  without a window, or a window without a socket, because the same list builds both.

  Within a lane the order is now the OPPOSITE of what this said: `LaneSupervisor` starts the
  ACCOUNTANT first and the transport after it, because `:rest_for_one` derives the restart
  asymmetry from that order. Nothing admits against a transport that does not exist regardless --
  the accountant starts CLOSED and only opens when a transport registers -- so the ordering
  argument this text used to make was never the thing that held.

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

  alias ServiceRadar.Edge.LaneSupervisor
  alias ServiceRadar.Edge.PublisherLane
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
  One lane restart-unit per `PublisherLane.lanes/0`, or NOTHING.

  Returns `[]` when the NATS settings cannot be built. That is deliberate and it is the corrected
  behaviour: an earlier version turned a settings error into an empty CONNECTION list but still
  appended all three pools, so `init/1` succeeded with windows whose named connections could not
  exist -- admitting frames against transport that was never going to be there, while claiming the
  connection/window pairing was structural. Publishing then fails closed for want of a pool, which
  is the safe direction.
  """
  def child_specs(opts \\ []) do
    case NATSSupervisor.connection_settings() do
      {:ok, settings, backoff} ->
        Enum.map(PublisherLane.lanes(), fn lane ->
          Supervisor.child_spec(
            {LaneSupervisor,
             lane: lane,
             connection_settings: settings,
             backoff_period: backoff,
             credits: credits_for(lane, opts)},
            id: LaneSupervisor.via(lane)
          )
        end)

      {:error, reason} ->
        Logger.error(
          "edge publisher lanes not started: NATS settings unavailable (#{inspect(reason)}). " <>
            "Publishes will fail closed rather than run unbounded."
        )

        []
    end
  end

  @doc "The lane connection names this supervisor owns, through its lane units."
  def lane_connection_names, do: Enum.map(PublisherLane.lanes(), &PublisherLane.connection_name/1)

  @impl true
  def init(opts) do
    Supervisor.init(child_specs(opts), strategy: :one_for_one)
  end

  defp pick(key, opts, lane_config, config, default) do
    Keyword.get(opts, key) || Keyword.get(lane_config, key) || Keyword.get(config, key) || default
  end
end
