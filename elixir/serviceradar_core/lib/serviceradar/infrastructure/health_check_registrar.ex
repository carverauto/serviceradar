defmodule ServiceRadar.Infrastructure.HealthCheckRegistrar do
  @moduledoc """
  Subscribes to agent registration events and automatically registers
  services for health checking with the HealthCheckRunner.

  When an agent registers and reports its monitored services, this process:
  1. Receives the registration event via PubSub
  2. Extracts the services the agent monitors
  3. Registers each service with the tenant's HealthCheckRunner
  4. Unregisters services when agents disconnect

  ## Architecture

      ┌─────────────────┐
      │  AgentRegistry  │ ──► broadcasts :agent_registered
      └────────┬────────┘
               │
               ▼
      ┌─────────────────────────┐
      │  HealthCheckRegistrar   │ (subscribes to PubSub)
      └────────┬────────────────┘
               │
               ▼
      ┌─────────────────────────┐
      │   HealthCheckRunner     │ (per-tenant, registers services)
      └─────────────────────────┘

  ## Monitored Service Types

  Services that agents can monitor (via gRPC to external Go/Rust services):
  - `:datasvc` - Data service nodes
  - `:sync` - Sync service nodes
  - `:zen` - Zen monitoring nodes
  - `:custom` - Custom external services

  ## Configuration

      config :serviceradar_core, ServiceRadar.Infrastructure.HealthCheckRegistrar,
        enabled: true,
        health_interval: 5_000,    # Default health check interval
        results_interval: 60_000   # Default results poll interval
  """

  use GenServer

  alias ServiceRadar.Infrastructure.HealthCheckRunner

  require Logger

  @default_health_interval :timer.seconds(5)
  @default_results_interval :timer.minutes(1)

  defstruct [
    :health_interval,
    :results_interval,
    # Track registered services per agent: %{agent_uid => [service_ids]}
    registered_services: %{}
  ]

  # =============================================================================
  # Client API
  # =============================================================================

  @doc """
  Starts the health check registrar.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Manually registers a service for health checking.

  Use this when onboarding a new service outside of the agent registration flow.
  """
  @spec register_service(String.t(), map()) :: :ok | {:error, term()}
  def register_service(tenant_id, service_config) do
    GenServer.call(__MODULE__, {:register_service, tenant_id, service_config})
  end

  @doc """
  Manually unregisters a service from health checking.
  """
  @spec unregister_service(String.t(), String.t()) :: :ok
  def unregister_service(tenant_id, service_id) do
    GenServer.call(__MODULE__, {:unregister_service, tenant_id, service_id})
  end

  @doc """
  Gets the current registration status.
  """
  @spec status() :: {:ok, map()}
  def status do
    GenServer.call(__MODULE__, :status)
  end

  # =============================================================================
  # GenServer Callbacks
  # =============================================================================

  @impl true
  def init(opts) do
    config = Application.get_env(:serviceradar_core, __MODULE__, [])

    health_interval = Keyword.get(opts, :health_interval) ||
                      Keyword.get(config, :health_interval, @default_health_interval)

    results_interval = Keyword.get(opts, :results_interval) ||
                       Keyword.get(config, :results_interval, @default_results_interval)

    state = %__MODULE__{
      health_interval: health_interval,
      results_interval: results_interval,
      registered_services: %{}
    }

    # Subscribe to agent registration events (global topic for all tenants)
    Phoenix.PubSub.subscribe(ServiceRadar.PubSub, "agent:registrations")

    # Subscribe to gateway registration events
    Phoenix.PubSub.subscribe(ServiceRadar.PubSub, "gateway:registrations")

    Logger.info("HealthCheckRegistrar started, subscribed to registration events")

    {:ok, state}
  end

  @impl true
  def handle_call({:register_service, tenant_id, service_config}, _from, state) do
    result = do_register_service(tenant_id, service_config, state)
    {:reply, result, state}
  end

  def handle_call({:unregister_service, tenant_id, service_id}, _from, state) do
    result = do_unregister_service(tenant_id, service_id)
    {:reply, result, state}
  end

  def handle_call(:status, _from, state) do
    status = %{
      health_interval: state.health_interval,
      results_interval: state.results_interval,
      registered_agents: Map.keys(state.registered_services),
      total_services: state.registered_services
                      |> Map.values()
                      |> List.flatten()
                      |> length()
    }

    {:reply, {:ok, status}, state}
  end

  @impl true
  def handle_info({:agent_registered, agent_info}, state) do
    Logger.info("Agent registered: #{inspect(agent_info[:agent_id])}")
    state = handle_agent_registered(agent_info, state)
    {:noreply, state}
  end

  def handle_info({:agent_disconnected, agent_id, tenant_id}, state) do
    Logger.info("Agent disconnected: #{agent_id}")
    state = handle_agent_disconnected(agent_id, tenant_id, state)
    {:noreply, state}
  end

  def handle_info({:agent_disconnected, agent_id}, state) do
    # Legacy format without tenant_id - try to find tenant from registered services
    Logger.info("Agent disconnected (legacy): #{agent_id}")
    state = handle_agent_disconnected_legacy(agent_id, state)
    {:noreply, state}
  end

  def handle_info({:gateway_registered, _gateway_info}, state) do
    # Gateways don't monitor services directly, but we log for visibility
    Logger.debug("Gateway registered event received")
    {:noreply, state}
  end

  def handle_info({:gateway_disconnected, _gateway_id}, state) do
    Logger.debug("Gateway disconnected event received")
    {:noreply, state}
  end

  def handle_info({:gateway_disconnected, _gateway_id, _tenant_id}, state) do
    Logger.debug("Gateway disconnected event received")
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.debug("HealthCheckRegistrar received unknown message: #{inspect(msg)}")
    {:noreply, state}
  end

  # =============================================================================
  # Private Functions
  # =============================================================================

  defp handle_agent_registered(agent_info, state) do
    tenant_id = agent_info[:tenant_id]
    agent_id = agent_info[:agent_id]
    services = agent_info[:monitored_services] || []

    if tenant_id && Enum.any?(services) do
      # Get or start the HealthCheckRunner for this tenant
      case HealthCheckRunner.get_or_start(tenant_id) do
        {:ok, _pid} ->
          # Register each service the agent monitors
          service_ids = register_agent_services(tenant_id, agent_id, services, state)

          # Track registered services for this agent
          new_registered = Map.put(state.registered_services, agent_id, service_ids)
          %{state | registered_services: new_registered}

        {:error, reason} ->
          Logger.warning("Failed to start HealthCheckRunner for tenant #{tenant_id}: #{inspect(reason)}")
          state
      end
    else
      Logger.debug("Agent #{agent_id} has no monitored services to register")
      state
    end
  end

  defp handle_agent_disconnected(agent_id, tenant_id, state) do
    # Get the services we registered for this agent
    case Map.get(state.registered_services, agent_id) do
      nil ->
        state

      service_ids ->
        # Unregister each service
        unregister_agent_services(tenant_id, service_ids)

        # Remove from tracking
        new_registered = Map.delete(state.registered_services, agent_id)
        %{state | registered_services: new_registered}
    end
  end

  defp handle_agent_disconnected_legacy(agent_id, state) do
    # Without tenant_id, we can't unregister properly
    # Just remove from our tracking
    case Map.get(state.registered_services, agent_id) do
      nil ->
        state

      _service_ids ->
        Logger.warning("Agent #{agent_id} disconnected but cannot unregister services (no tenant_id)")
        new_registered = Map.delete(state.registered_services, agent_id)
        %{state | registered_services: new_registered}
    end
  end

  defp register_agent_services(tenant_id, agent_id, services, state) do
    Enum.map(services, fn service ->
      service_config = build_service_config(service, agent_id, state)

      case do_register_service(tenant_id, service_config, state) do
        :ok ->
          Logger.info("Registered service #{service_config.service_id} for health checking")
          service_config.service_id

        {:error, reason} ->
          Logger.warning("Failed to register service: #{inspect(reason)}")
          nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp unregister_agent_services(tenant_id, service_ids) do
    Enum.each(service_ids, fn service_id ->
      do_unregister_service(tenant_id, service_id)
    end)
  end

  defp build_service_config(service, agent_id, state) do
    # Service can be a map or a simple atom/string
    case service do
      %{} = svc ->
        %{
          service_id: svc[:service_id] || svc[:id] || generate_service_id(svc),
          service_type: svc[:service_type] || svc[:type] || :custom,
          agent_uid: agent_id,
          target: svc[:target] || svc[:address],
          health_interval: svc[:health_interval] || state.health_interval,
          results_interval: svc[:results_interval] || state.results_interval,
          config: Map.drop(svc, [:service_id, :id, :service_type, :type, :target, :address])
        }

      type when is_atom(type) ->
        %{
          service_id: "#{type}-#{agent_id}",
          service_type: type,
          agent_uid: agent_id,
          target: nil,
          health_interval: state.health_interval,
          results_interval: state.results_interval,
          config: %{}
        }

      name when is_binary(name) ->
        %{
          service_id: "#{name}-#{agent_id}",
          service_type: :custom,
          agent_uid: agent_id,
          target: nil,
          health_interval: state.health_interval,
          results_interval: state.results_interval,
          config: %{}
        }
    end
  end

  defp generate_service_id(service) do
    type = service[:service_type] || service[:type] || "svc"
    id = service[:id] || :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
    "#{type}-#{id}"
  end

  defp do_register_service(tenant_id, service_config, _state) do
    case HealthCheckRunner.get_or_start(tenant_id) do
      {:ok, pid} ->
        HealthCheckRunner.register_service(pid, service_config)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_unregister_service(tenant_id, service_id) do
    # Use the same via_tuple pattern as HealthCheckRunner
    name = {:via, Registry, {ServiceRadar.LocalRegistry, {HealthCheckRunner, tenant_id}}}

    case GenServer.whereis(name) do
      nil ->
        :ok

      pid ->
        HealthCheckRunner.unregister_service(pid, service_id)
    end
  rescue
    _ -> :ok
  end
end
