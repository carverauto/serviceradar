defmodule ServiceRadar.Infrastructure.HealthCheckRunner do
  @moduledoc """
  High-frequency health check runner for gRPC-based service checks.

  Performs sub-minute health checks via gateways to agents. AshOban can only
  schedule per-minute, so this GenServer handles high-frequency checks
  (e.g., every 5 seconds).

  ## Architecture

      ┌─────────────────┐
      │ HealthCheckRunner │ (singleton GenServer)
      └────────┬────────┘
               │ gRPC via gateway
               ▼
      ┌─────────────────┐
      │     Gateway     │
      └────────┬────────┘
               │ gRPC
               ▼
      ┌─────────────────┐
      │     Agent       │ ──► External Services (datasvc, sync, zen)
      └─────────────────┘

  ## Check Types

  - `:grpc_health` - gRPC health check (GetStatus)
  - `:grpc_results` - gRPC results poll (GetResults)

  ## Configuration

      config :serviceradar_core, ServiceRadar.Infrastructure.HealthCheckRunner,
        default_health_interval: 5_000,   # 5 seconds
        default_results_interval: 60_000, # 1 minute
        check_timeout: 10_000             # 10 second timeout

  ## Usage

      # Get or start the runner
      {:ok, pid} = HealthCheckRunner.get_or_start()

      # Register a service for health checking
      HealthCheckRunner.register_service(pid, %{
        service_id: "datasvc-node-1",
        service_type: :datasvc,
        agent_uid: "agent-001",
        health_interval: 5_000,
        results_interval: 60_000
      })

      # Unregister a service
      HealthCheckRunner.unregister_service(pid, "datasvc-node-1")
  """

  use GenServer

  alias ServiceRadar.Edge.GatewayProcess
  alias ServiceRadar.GatewayRegistry
  alias ServiceRadar.Infrastructure.HealthTracker

  require Logger

  @default_health_interval :timer.seconds(5)
  @default_results_interval :timer.minutes(1)
  @check_timeout :timer.seconds(10)

  defstruct services: %{},
            timers: %{}

  @type service_config :: %{
          service_id: String.t(),
          service_type: atom(),
          agent_uid: String.t(),
          health_interval: non_neg_integer(),
          results_interval: non_neg_integer(),
          target: String.t() | nil,
          config: map()
        }

  # =============================================================================
  # Client API
  # =============================================================================

  @doc """
  Starts or gets the health check runner.

  If a runner already exists, returns {:ok, pid}.
  Otherwise starts a new runner under the DynamicSupervisor.
  """
  @spec get_or_start(keyword()) :: {:ok, pid()} | {:error, term()}
  def get_or_start(opts \\ []) do
    case GenServer.whereis(__MODULE__) do
      nil ->
        start_runner(opts)

      pid ->
        {:ok, pid}
    end
  end

  @doc """
  Starts a new health check runner.
  """
  @spec start_runner(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_runner(opts \\ []) do
    child_spec = %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient
    }

    DynamicSupervisor.start_child(
      ServiceRadar.Infrastructure.HealthCheckRunnerSupervisor,
      child_spec
    )
  end

  @doc """
  Stops the health check runner.
  """
  @spec stop() :: :ok | {:error, :not_found}
  def stop do
    case GenServer.whereis(__MODULE__) do
      nil ->
        {:error, :not_found}

      pid ->
        DynamicSupervisor.terminate_child(
          ServiceRadar.Infrastructure.HealthCheckRunnerSupervisor,
          pid
        )
    end
  end

  @doc """
  Starts the health check runner (called by supervisor).
  """
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Registers a service for health checking.

  ## Options

  - `:service_id` - Unique identifier for the service (required)
  - `:service_type` - Type of service: :datasvc, :sync, :zen, :custom (required)
  - `:agent_uid` - Agent that can reach this service (required)
  - `:health_interval` - Health check interval in ms (default: 5000)
  - `:results_interval` - Results poll interval in ms (default: 60000)
  - `:target` - Target address/endpoint for the service
  - `:config` - Additional service-specific config
  """
  @spec register_service(GenServer.server(), map()) :: :ok | {:error, term()}
  def register_service(server, service_config) do
    GenServer.call(server, {:register_service, service_config})
  end

  @doc """
  Unregisters a service from health checking.
  """
  @spec unregister_service(GenServer.server(), String.t()) :: :ok
  def unregister_service(server, service_id) do
    GenServer.call(server, {:unregister_service, service_id})
  end

  @doc """
  Lists all registered services.
  """
  @spec list_services(GenServer.server()) :: [service_config()]
  def list_services(server) do
    GenServer.call(server, :list_services)
  end

  @doc """
  Triggers an immediate health check for a service.
  """
  @spec check_now(GenServer.server(), String.t()) :: :ok
  def check_now(server, service_id) do
    GenServer.cast(server, {:check_now, service_id})
  end

  # =============================================================================
  # GenServer Callbacks
  # =============================================================================

  @impl true
  def init(_opts) do
    Logger.info("Starting HealthCheckRunner")

    state = %__MODULE__{
      services: %{},
      timers: %{}
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:register_service, config}, _from, state) do
    service_id = Map.fetch!(config, :service_id)

    # Cancel existing timers if re-registering
    state = cancel_service_timers(state, service_id)

    # Normalize config with defaults
    service = normalize_service_config(config)

    # Schedule health checks
    health_timer = schedule_health_check(service_id, service.health_interval)
    results_timer = schedule_results_check(service_id, service.results_interval)

    new_services = Map.put(state.services, service_id, service)

    new_timers =
      state.timers
      |> Map.put({service_id, :health}, health_timer)
      |> Map.put({service_id, :results}, results_timer)

    Logger.info("Registered service #{service_id} (#{service.service_type}) for health checks")

    {:reply, :ok, %{state | services: new_services, timers: new_timers}}
  end

  def handle_call({:unregister_service, service_id}, _from, state) do
    state = cancel_service_timers(state, service_id)
    new_services = Map.delete(state.services, service_id)

    Logger.info("Unregistered service #{service_id} from health checks")

    {:reply, :ok, %{state | services: new_services}}
  end

  def handle_call(:list_services, _from, state) do
    {:reply, Map.values(state.services), state}
  end

  @impl true
  def handle_cast({:check_now, service_id}, state) do
    case Map.get(state.services, service_id) do
      nil ->
        Logger.warning("Service #{service_id} not registered for health checks")

      service ->
        run_health_check(service)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:health_check, service_id}, state) do
    case Map.get(state.services, service_id) do
      nil ->
        {:noreply, state}

      service ->
        # Run the check asynchronously
        Task.start(fn ->
          run_health_check(service)
        end)

        # Reschedule
        timer = schedule_health_check(service_id, service.health_interval)
        new_timers = Map.put(state.timers, {service_id, :health}, timer)

        {:noreply, %{state | timers: new_timers}}
    end
  end

  def handle_info({:results_check, service_id}, state) do
    case Map.get(state.services, service_id) do
      nil ->
        {:noreply, state}

      service ->
        # Run the results poll asynchronously
        Task.start(fn ->
          run_results_check(service)
        end)

        # Reschedule
        timer = schedule_results_check(service_id, service.results_interval)
        new_timers = Map.put(state.timers, {service_id, :results}, timer)

        {:noreply, %{state | timers: new_timers}}
    end
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    # Cancel all timers
    Enum.each(state.timers, fn {_key, timer} ->
      Process.cancel_timer(timer)
    end)

    :ok
  end

  # =============================================================================
  # Private Functions
  # =============================================================================

  defp normalize_service_config(config) do
    %{
      service_id: Map.fetch!(config, :service_id),
      service_type: Map.fetch!(config, :service_type),
      agent_uid: Map.fetch!(config, :agent_uid),
      health_interval: Map.get(config, :health_interval, config(:default_health_interval)),
      results_interval: Map.get(config, :results_interval, config(:default_results_interval)),
      target: Map.get(config, :target),
      config: Map.get(config, :config, %{})
    }
  end

  defp schedule_health_check(service_id, interval) do
    Process.send_after(self(), {:health_check, service_id}, interval)
  end

  defp schedule_results_check(service_id, interval) do
    Process.send_after(self(), {:results_check, service_id}, interval)
  end

  defp cancel_service_timers(state, service_id) do
    # Cancel health timer
    case Map.get(state.timers, {service_id, :health}) do
      nil -> :ok
      timer -> Process.cancel_timer(timer)
    end

    # Cancel results timer
    case Map.get(state.timers, {service_id, :results}) do
      nil -> :ok
      timer -> Process.cancel_timer(timer)
    end

    # Remove from timers map
    new_timers =
      state.timers
      |> Map.delete({service_id, :health})
      |> Map.delete({service_id, :results})

    %{state | timers: new_timers}
  end

  defp run_health_check(service) do
    Logger.debug("Running health check for #{service.service_id}")

    start_time = System.monotonic_time(:millisecond)

    result = execute_grpc_health_check(service)

    duration = System.monotonic_time(:millisecond) - start_time

    # Record the result via HealthTracker
    case result do
      {:ok, status} ->
        HealthTracker.record_health_check(
          service.service_type,
          service.service_id,
          healthy: status == :serving,
          latency_ms: duration,
          metadata: %{check_type: :grpc_health}
        )

      {:error, reason} ->
        HealthTracker.record_health_check(
          service.service_type,
          service.service_id,
          healthy: false,
          latency_ms: duration,
          error: inspect(reason),
          metadata: %{check_type: :grpc_health}
        )
    end

    :telemetry.execute(
      [:serviceradar, :infrastructure, :health_check_runner, :check],
      %{duration: duration},
      %{
        service_id: service.service_id,
        service_type: service.service_type,
        check_type: :health,
        success: match?({:ok, _}, result)
      }
    )
  end

  defp run_results_check(service) do
    Logger.debug("Running results check for #{service.service_id}")

    start_time = System.monotonic_time(:millisecond)

    result = execute_grpc_get_results(service)

    duration = System.monotonic_time(:millisecond) - start_time

    case result do
      {:ok, results} ->
        # Process and record results
        process_check_results(service, results)

      {:error, reason} ->
        Logger.warning("Failed to get results for #{service.service_id}: #{inspect(reason)}")
    end

    :telemetry.execute(
      [:serviceradar, :infrastructure, :health_check_runner, :check],
      %{duration: duration},
      %{
        service_id: service.service_id,
        service_type: service.service_type,
        check_type: :results,
        success: match?({:ok, _}, result)
      }
    )
  end

  defp execute_grpc_health_check(service) do
    # Find a gateway that can reach this agent
    case find_gateway_for_agent(service.agent_uid) do
      {:ok, gateway_id} ->
        # Make gRPC call through the gateway
        # The gateway will forward to the agent, which checks the service
        call_gateway_health_check(gateway_id, service)

      {:error, :no_gateway} ->
        {:error, :no_gateway_available}
    end
  end

  defp execute_grpc_get_results(service) do
    case find_gateway_for_agent(service.agent_uid) do
      {:ok, gateway_id} ->
        call_gateway_get_results(gateway_id, service)

      {:error, :no_gateway} ->
        {:error, :no_gateway_available}
    end
  end

  defp find_gateway_for_agent(_agent_uid) do
    # Look up available gateways
    # The gateway will find the appropriate agent
    case GatewayRegistry.find_available_gateways() do
      [gateway | _rest] ->
        # For now, use first available gateway
        # TODO: Could be smarter about routing to the right gateway based on agent_uid
        gateway_id = gateway[:gateway_id]
        {:ok, gateway_id}

      [] ->
        {:error, :no_gateway}
    end
  end

  defp call_gateway_health_check(gateway_id, service) do
    # Call the gateway process to perform health check
    # The gateway will forward to the agent via gRPC
    GatewayProcess.health_check(gateway_id, service)
  catch
    :exit, {:timeout, _} ->
      {:error, :timeout}

    :exit, reason ->
      {:error, reason}
  end

  defp call_gateway_get_results(gateway_id, service) do
    GatewayProcess.get_results(gateway_id, service)
  catch
    :exit, {:timeout, _} ->
      {:error, :timeout}

    :exit, reason ->
      {:error, reason}
  end

  defp process_check_results(_service, _results) do
    # Process results from GetResults call
    # This would update metrics, trigger alerts, etc.
    # Implementation depends on what the service returns
    :ok
  end

  defp config(key) do
    app_config = Application.get_env(:serviceradar_core, __MODULE__, [])

    case key do
      :default_health_interval ->
        Keyword.get(app_config, :default_health_interval, @default_health_interval)

      :default_results_interval ->
        Keyword.get(app_config, :default_results_interval, @default_results_interval)

      :check_timeout ->
        Keyword.get(app_config, :check_timeout, @check_timeout)
    end
  end
end
