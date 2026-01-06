defmodule ServiceRadar.Infrastructure.ServiceHeartbeat do
  @moduledoc """
  GenServer for Elixir service self-reporting via heartbeats.

  Runs in each Elixir service node (core, web-ng, gateway) and periodically
  reports health status to the HealthTracker. This enables:

  - Automatic health monitoring of Elixir services
  - Detection of service failures via missed heartbeats
  - Unified health tracking across all infrastructure

  ## Architecture

      ┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
      │  Core Node      │     │  Web Node       │     │  Gateway Node   │
      │  (ServiceHB)    │     │  (ServiceHB)    │     │  (ServiceHB)    │
      └────────┬────────┘     └────────┬────────┘     └────────┬────────┘
               │                       │                       │
               └───────────────────────┼───────────────────────┘
                                       │
                                       ▼
                           ┌───────────────────────┐
                           │    HealthTracker      │
                           │  (records heartbeats) │
                           └───────────┬───────────┘
                                       │
                           ┌───────────┴───────────┐
                           │                       │
                           ▼                       ▼
                   ┌───────────────┐       ┌───────────────┐
                   │  HealthEvent  │       │     NATS      │
                   │  (database)   │       │  (real-time)  │
                   └───────────────┘       └───────────────┘

  ## Configuration

      config :serviceradar_core, ServiceRadar.Infrastructure.ServiceHeartbeat,
        service_type: :core,           # :core | :web | :gateway
        tenant_id: "platform",         # Platform-level tenant for system services
        interval: 30_000,              # Heartbeat interval in ms
        enabled: true

  ## Usage

  Started automatically by the application supervisor if configured:

      # In application.ex
      defp service_heartbeat_child do
        if heartbeat_enabled?() do
          ServiceRadar.Infrastructure.ServiceHeartbeat
        end
      end

  Can also be started manually:

      {:ok, pid} = ServiceHeartbeat.start_link(
        service_type: :core,
        tenant_id: tenant_id,
        interval: 30_000
      )
  """

  use GenServer

  alias ServiceRadar.Infrastructure.HealthTracker

  require Logger

  @default_interval :timer.seconds(30)

  defstruct [
    :service_type,
    :service_id,
    :tenant_id,
    :interval,
    :started_at,
    :last_heartbeat_at,
    :heartbeat_count
  ]

  # =============================================================================
  # Client API
  # =============================================================================

  @doc """
  Starts the service heartbeat process.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Gets the current heartbeat status.
  """
  @spec status() :: {:ok, map()} | {:error, :not_started}
  def status do
    if Process.whereis(__MODULE__) do
      GenServer.call(__MODULE__, :status)
    else
      {:error, :not_started}
    end
  end

  @doc """
  Triggers an immediate heartbeat.
  """
  @spec heartbeat_now() :: :ok | {:error, :not_started}
  def heartbeat_now do
    if Process.whereis(__MODULE__) do
      GenServer.cast(__MODULE__, :heartbeat_now)
    else
      {:error, :not_started}
    end
  end

  @doc """
  Reports that the service is degraded with a reason.
  """
  @spec report_degraded(atom()) :: :ok | {:error, :not_started}
  def report_degraded(reason) do
    if Process.whereis(__MODULE__) do
      GenServer.cast(__MODULE__, {:report_degraded, reason})
    else
      {:error, :not_started}
    end
  end

  @doc """
  Reports that the service has recovered.
  """
  @spec report_recovered() :: :ok | {:error, :not_started}
  def report_recovered do
    if Process.whereis(__MODULE__) do
      GenServer.cast(__MODULE__, :report_recovered)
    else
      {:error, :not_started}
    end
  end

  # =============================================================================
  # GenServer Callbacks
  # =============================================================================

  @impl true
  def init(opts) do
    config = Application.get_env(:serviceradar_core, __MODULE__, [])

    service_type = Keyword.get(opts, :service_type) ||
                   Keyword.get(config, :service_type, :core)

    tenant_id = Keyword.get(opts, :tenant_id) ||
                Keyword.get(config, :tenant_id) ||
                get_platform_tenant_id()

    interval = Keyword.get(opts, :interval) ||
               Keyword.get(config, :interval, @default_interval)

    service_id = generate_service_id(service_type)

    state = %__MODULE__{
      service_type: service_type,
      service_id: service_id,
      tenant_id: tenant_id,
      interval: interval,
      started_at: DateTime.utc_now(),
      last_heartbeat_at: nil,
      heartbeat_count: 0
    }

    Logger.info("Starting ServiceHeartbeat for #{service_type} (#{service_id})")

    # Send initial heartbeat
    send(self(), :heartbeat)

    {:ok, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    status = %{
      service_type: state.service_type,
      service_id: state.service_id,
      tenant_id: state.tenant_id,
      interval: state.interval,
      started_at: state.started_at,
      last_heartbeat_at: state.last_heartbeat_at,
      heartbeat_count: state.heartbeat_count,
      uptime_seconds: DateTime.diff(DateTime.utc_now(), state.started_at, :second)
    }

    {:reply, {:ok, status}, state}
  end

  @impl true
  def handle_cast(:heartbeat_now, state) do
    state = send_heartbeat(state, true)
    {:noreply, state}
  end

  def handle_cast({:report_degraded, reason}, state) do
    Logger.warning("Service #{state.service_type} reporting degraded: #{reason}")

    if state.tenant_id do
      HealthTracker.record_state_change(
        state.service_type,
        state.service_id,
        state.tenant_id,
        old_state: :healthy,
        new_state: :degraded,
        reason: reason,
        metadata: build_metadata(state)
      )
    end

    {:noreply, state}
  end

  def handle_cast(:report_recovered, state) do
    Logger.info("Service #{state.service_type} reporting recovered")

    if state.tenant_id do
      HealthTracker.record_state_change(
        state.service_type,
        state.service_id,
        state.tenant_id,
        old_state: :degraded,
        new_state: :healthy,
        reason: :recovery,
        metadata: build_metadata(state)
      )
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(:heartbeat, state) do
    state = send_heartbeat(state, true)
    schedule_heartbeat(state.interval)
    {:noreply, state}
  end

  @impl true
  def terminate(reason, state) do
    Logger.info("ServiceHeartbeat for #{state.service_type} terminating: #{inspect(reason)}")

    # Record offline event if we have a tenant
    if state.tenant_id do
      HealthTracker.record_state_change(
        state.service_type,
        state.service_id,
        state.tenant_id,
        old_state: :healthy,
        new_state: :offline,
        reason: :shutdown,
        metadata: build_metadata(state)
      )
    end

    :ok
  end

  # =============================================================================
  # Private Functions
  # =============================================================================

  defp send_heartbeat(state, healthy) do
    now = DateTime.utc_now()

    if state.tenant_id do
      metadata = build_metadata(state)

      HealthTracker.heartbeat(
        state.service_type,
        state.service_id,
        state.tenant_id,
        healthy: healthy,
        metadata: metadata
      )

      Logger.debug("Heartbeat sent for #{state.service_type} (#{state.service_id})")
    else
      Logger.debug("Skipping heartbeat - no tenant_id configured")
    end

    %{state |
      last_heartbeat_at: now,
      heartbeat_count: state.heartbeat_count + 1
    }
  end

  defp schedule_heartbeat(interval) do
    Process.send_after(self(), :heartbeat, interval)
  end

  defp generate_service_id(service_type) do
    node_name = Node.self() |> to_string()
    "#{service_type}-#{node_name}"
  end

  defp build_metadata(state) do
    %{
      node: Node.self() |> to_string(),
      uptime_seconds: DateTime.diff(DateTime.utc_now(), state.started_at, :second),
      heartbeat_count: state.heartbeat_count,
      version: Application.spec(:serviceradar_core, :vsn) |> to_string(),
      otp_release: System.otp_release(),
      memory_mb: div(:erlang.memory(:total), 1_048_576),
      process_count: :erlang.system_info(:process_count)
    }
  end

  defp get_platform_tenant_id do
    # Try to get platform tenant from config or environment
    case System.get_env("PLATFORM_TENANT_ID") do
      nil -> Application.get_env(:serviceradar_core, :platform_tenant_id)
      id -> id
    end
  end
end
