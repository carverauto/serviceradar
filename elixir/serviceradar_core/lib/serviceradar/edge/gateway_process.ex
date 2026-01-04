defmodule ServiceRadar.Edge.GatewayProcess do
  @moduledoc """
  GenServer representing an agent gateway in the ERTS cluster.

  The GatewayProcess is responsible for:
  1. Registering with the GatewayRegistry for discoverability
  2. Accepting poll requests from Core (via AshOban scheduled jobs)
  3. Finding available agents in the correct partition
  4. Dispatching check requests to agents
  5. Aggregating and reporting results

  ## Communication Pattern

  Core (AshOban) -> Gateway -> Agent -> serviceradar-sync

  ## Starting a Gateway

      {:ok, pid} = ServiceRadar.Edge.GatewayProcess.start_link(
        gateway_id: "gateway-uuid",
        tenant_id: "tenant-uuid",
        partition_id: "partition-1"
      )
  """

  use GenServer

  require Logger

  alias ServiceRadar.GatewayRegistry
  alias ServiceRadar.AgentRegistry
  alias ServiceRadar.Edge.AgentProcess

  @type state :: %{
          gateway_id: String.t(),
          tenant_id: String.t(),
          partition_id: String.t(),
          status: :idle | :executing,
          current_job: map() | nil,
          metrics: map()
        }

  @health_check_interval 30_000

  # Client API

  @doc """
  Start a gateway process.
  """
  def start_link(opts) do
    gateway_id = Keyword.fetch!(opts, :gateway_id)
    GenServer.start_link(__MODULE__, opts, name: via_tuple(gateway_id))
  end

  @doc """
  Execute a polling job on this gateway.

  The gateway will find an available agent and dispatch the checks.
  """
  @spec execute_job(String.t() | pid(), map()) :: {:ok, map()} | {:error, term()}
  def execute_job(gateway, job) when is_binary(gateway) do
    case lookup_pid(gateway) do
      nil -> {:error, :gateway_not_found}
      pid -> execute_job(pid, job)
    end
  end

  def execute_job(gateway, job) when is_pid(gateway) do
    GenServer.call(gateway, {:execute_job, job}, 120_000)
  end

  @doc """
  Execute a job asynchronously.

  Returns immediately with a job_id. Results are broadcast via PubSub.
  """
  @spec execute_job_async(String.t() | pid(), map()) :: {:ok, String.t()} | {:error, term()}
  def execute_job_async(gateway, job) when is_binary(gateway) do
    case lookup_pid(gateway) do
      nil -> {:error, :gateway_not_found}
      pid -> execute_job_async(pid, job)
    end
  end

  def execute_job_async(gateway, job) when is_pid(gateway) do
    GenServer.call(gateway, {:execute_job_async, job}, 30_000)
  end

  @doc """
  Get the current status of this gateway.
  """
  @spec status(String.t() | pid()) :: {:ok, map()} | {:error, term()}
  def status(gateway) when is_binary(gateway) do
    case lookup_pid(gateway) do
      nil -> {:error, :gateway_not_found}
      pid -> status(pid)
    end
  end

  def status(gateway) when is_pid(gateway) do
    GenServer.call(gateway, :status)
  end

  @doc """
  Execute a health check for a service via an agent.

  Used by HealthCheckRunner for high-frequency health monitoring.
  The gateway forwards the request to an available agent which performs
  the actual gRPC health check on the target service.

  ## Service Config

  - `:service_id` - Unique identifier for the service
  - `:service_type` - Type of service (e.g., :datasvc, :sync, :zen)
  - `:agent_uid` - Target agent to perform the check
  - `:target` - Target address/endpoint (optional)
  - `:config` - Additional service-specific config
  """
  @spec health_check(String.t() | pid(), map()) :: {:ok, atom()} | {:error, term()}
  def health_check(gateway, service) when is_binary(gateway) do
    case lookup_pid(gateway) do
      nil -> {:error, :gateway_not_found}
      pid -> health_check(pid, service)
    end
  end

  def health_check(gateway, service) when is_pid(gateway) do
    GenServer.call(gateway, {:health_check, service}, 30_000)
  end

  @doc """
  Get check results from a service via an agent.

  Used by HealthCheckRunner to poll for accumulated check results
  from external services monitored by agents.
  """
  @spec get_results(String.t() | pid(), map()) :: {:ok, list()} | {:error, term()}
  def get_results(gateway, service) when is_binary(gateway) do
    case lookup_pid(gateway) do
      nil -> {:error, :gateway_not_found}
      pid -> get_results(pid, service)
    end
  end

  def get_results(gateway, service) when is_pid(gateway) do
    GenServer.call(gateway, {:get_results, service}, 30_000)
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    gateway_id = Keyword.fetch!(opts, :gateway_id)
    tenant_id = Keyword.fetch!(opts, :tenant_id)
    partition_id = Keyword.get(opts, :partition_id, "default")
    domain = Keyword.get(opts, :domain)

    state = %{
      gateway_id: gateway_id,
      tenant_id: tenant_id,
      partition_id: partition_id,
      domain: domain,
      status: :idle,
      current_job: nil,
      metrics: %{
        jobs_executed: 0,
        checks_executed: 0,
        last_execution_at: nil,
        avg_execution_time_ms: 0
      }
    }

    # Register with the registry
    register_gateway(state)

    # Schedule health checks
    schedule_health_check()

    Logger.info("Gateway #{gateway_id} started for tenant #{tenant_id}/#{partition_id}")

    {:ok, state}
  end

  @impl true
  def handle_call({:execute_job, _job}, _from, %{status: :executing} = state) do
    {:reply, {:error, :busy}, state}
  end

  def handle_call({:execute_job, job}, _from, state) do
    state = %{state | status: :executing, current_job: job}
    start_time = System.monotonic_time(:millisecond)

    result = execute_job_impl(job, state)

    elapsed = System.monotonic_time(:millisecond) - start_time
    state = update_metrics(state, elapsed, job)
    state = %{state | status: :idle, current_job: nil}

    {:reply, result, state}
  end

  def handle_call({:execute_job_async, _job}, _from, %{status: :executing} = state) do
    {:reply, {:error, :busy}, state}
  end

  def handle_call({:execute_job_async, job}, _from, state) do
    job_id = generate_job_id()

    parent = self()

    spawn(fn ->
      result = GenServer.call(parent, {:execute_job, job}, 120_000)

      Phoenix.PubSub.broadcast(
        ServiceRadar.PubSub,
        "gateway:results:#{state.gateway_id}",
        {:job_result, job_id, result}
      )
    end)

    {:reply, {:ok, job_id}, state}
  end

  def handle_call(:status, _from, state) do
    status = %{
      gateway_id: state.gateway_id,
      tenant_id: state.tenant_id,
      partition_id: state.partition_id,
      status: state.status,
      metrics: state.metrics
    }

    {:reply, {:ok, status}, state}
  end

  def handle_call({:health_check, service}, _from, state) do
    result = execute_health_check_impl(service, state)
    {:reply, result, state}
  end

  def handle_call({:get_results, service}, _from, state) do
    result = execute_get_results_impl(service, state)
    {:reply, result, state}
  end

  @impl true
  def handle_info(:health_check, state) do
    # Update registry heartbeat
    GatewayRegistry.heartbeat(state.tenant_id, state.gateway_id)
    schedule_health_check()
    {:noreply, state}
  end

  @impl true
  def terminate(reason, state) do
    Logger.info("Gateway #{state.gateway_id} terminating: #{inspect(reason)}")
    GatewayRegistry.unregister_gateway(state.tenant_id, state.gateway_id)
    :ok
  end

  # Private Functions

  defp via_tuple(gateway_id) do
    {:via, Registry, {ServiceRadar.LocalRegistry, {:gateway, gateway_id}}}
  end

  defp lookup_pid(gateway_id) do
    case Registry.lookup(ServiceRadar.LocalRegistry, {:gateway, gateway_id}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  defp register_gateway(state) do
    gateway_info = %{
      tenant_id: state.tenant_id,
      partition_id: state.partition_id,
      domain: state.domain,
      status: registry_status(state.status)
    }

    GatewayRegistry.register_gateway(state.gateway_id, gateway_info)
  end

  defp registry_status(:idle), do: :available
  defp registry_status(:executing), do: :busy
  defp registry_status(_), do: :available

  defp execute_job_impl(job, state) do
    checks = job[:checks] || []
    Logger.info("Gateway #{state.gateway_id} executing job with #{length(checks)} checks")

    # Find an available agent in our partition
    case find_available_agent(state) do
      nil ->
        Logger.warning("No available agents for partition #{state.partition_id}")
        {:error, :no_available_agents}

      agent ->
        execute_checks_on_agent(agent, checks, state)
    end
  end

  defp find_available_agent(state) do
    # Try domain-based selection first if gateway has a domain, then fall back to partition
    domain = Map.get(state, :domain)

    agents =
      if domain do
        # Try domain-based selection first
        domain_agents = AgentRegistry.find_agents_for_domain(state.tenant_id, domain)

        if Enum.empty?(domain_agents) do
          # Fall back to partition-based selection
          AgentRegistry.find_agents_for_partition(state.tenant_id, state.partition_id)
        else
          domain_agents
        end
      else
        # Use partition-based selection
        AgentRegistry.find_agents_for_partition(state.tenant_id, state.partition_id)
      end

    # Filter to connected agents and pick one
    connected_agents =
      Enum.filter(agents, fn agent ->
        agent[:status] == :connected
      end)

    case connected_agents do
      [] -> nil
      # Simple load balancing - random selection
      agents -> Enum.random(agents)
    end
  end

  defp execute_checks_on_agent(agent, checks, state) do
    agent_id = agent[:agent_id]
    Logger.debug("Dispatching #{length(checks)} checks to agent #{agent_id}")

    results =
      Enum.map(checks, fn check ->
        request = %{
          service_name: check[:service_name],
          service_type: check[:service_type],
          gateway_id: state.gateway_id,
          details: check[:details],
          port: check[:port]
        }

        case AgentProcess.execute_check(agent_id, request) do
          {:ok, result} ->
            %{check: check, result: result, status: :success}

          {:error, reason} ->
            %{check: check, error: reason, status: :failed}
        end
      end)

    success_count = Enum.count(results, &(&1[:status] == :success))
    failure_count = Enum.count(results, &(&1[:status] == :failed))

    {:ok,
     %{
       total: length(results),
       success: success_count,
       failed: failure_count,
       results: results
     }}
  end

  defp update_metrics(state, elapsed_ms, job) do
    checks = job[:checks] || []
    metrics = state.metrics

    new_jobs = metrics.jobs_executed + 1
    new_checks = metrics.checks_executed + length(checks)

    # Running average of execution time
    old_avg = metrics.avg_execution_time_ms || 0
    new_avg = (old_avg * metrics.jobs_executed + elapsed_ms) / new_jobs

    new_metrics = %{
      jobs_executed: new_jobs,
      checks_executed: new_checks,
      last_execution_at: DateTime.utc_now(),
      avg_execution_time_ms: new_avg
    }

    %{state | metrics: new_metrics}
  end

  defp schedule_health_check do
    Process.send_after(self(), :health_check, @health_check_interval)
  end

  defp generate_job_id do
    :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
  end

  defp execute_health_check_impl(service, state) do
    agent_uid = service[:agent_uid]

    case find_agent_by_uid(state, agent_uid) do
      nil ->
        Logger.warning("Agent #{agent_uid} not found for health check")
        {:error, :agent_not_found}

      agent ->
        agent_id = agent[:agent_id]
        Logger.debug("Forwarding health check for #{service[:service_id]} to agent #{agent_id}")

        case AgentProcess.health_check(agent_id, service) do
          {:ok, status} ->
            {:ok, status}

          {:error, reason} ->
            Logger.warning("Health check failed for #{service[:service_id]}: #{inspect(reason)}")
            {:error, reason}
        end
    end
  end

  defp execute_get_results_impl(service, state) do
    agent_uid = service[:agent_uid]

    case find_agent_by_uid(state, agent_uid) do
      nil ->
        Logger.warning("Agent #{agent_uid} not found for get_results")
        {:error, :agent_not_found}

      agent ->
        agent_id = agent[:agent_id]
        Logger.debug("Forwarding get_results for #{service[:service_id]} to agent #{agent_id}")

        case AgentProcess.get_results(agent_id, service) do
          {:ok, results} ->
            {:ok, results}

          {:error, reason} ->
            Logger.warning("Get results failed for #{service[:service_id]}: #{inspect(reason)}")
            {:error, reason}
        end
    end
  end

  defp find_agent_by_uid(state, agent_uid) do
    # Look up agents in the partition by UID
    agents = AgentRegistry.find_agents_for_partition(state.tenant_id, state.partition_id)

    Enum.find(agents, fn agent ->
      agent[:agent_id] == agent_uid or agent[:uid] == agent_uid
    end)
  end
end
