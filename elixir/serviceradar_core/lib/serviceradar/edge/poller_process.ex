defmodule ServiceRadar.Edge.PollerProcess do
  @moduledoc """
  GenServer representing a poller in the ERTS cluster.

  The PollerProcess is responsible for:
  1. Registering with the PollerRegistry for discoverability
  2. Accepting poll requests from Core (via AshOban scheduled jobs)
  3. Finding available agents in the correct partition
  4. Dispatching check requests to agents
  5. Aggregating and reporting results

  ## Communication Pattern

  Core (AshOban) -> Poller -> Agent -> serviceradar-sync

  ## Starting a Poller

      {:ok, pid} = ServiceRadar.Edge.PollerProcess.start_link(
        poller_id: "poller-uuid",
        tenant_id: "tenant-uuid",
        partition_id: "partition-1"
      )
  """

  use GenServer

  require Logger

  alias ServiceRadar.PollerRegistry
  alias ServiceRadar.AgentRegistry
  alias ServiceRadar.Edge.AgentProcess

  @type state :: %{
          poller_id: String.t(),
          tenant_id: String.t(),
          partition_id: String.t(),
          status: :idle | :executing,
          current_job: map() | nil,
          metrics: map()
        }

  @health_check_interval 30_000

  # Client API

  @doc """
  Start a poller process.
  """
  def start_link(opts) do
    poller_id = Keyword.fetch!(opts, :poller_id)
    GenServer.start_link(__MODULE__, opts, name: via_tuple(poller_id))
  end

  @doc """
  Execute a polling job on this poller.

  The poller will find an available agent and dispatch the checks.
  """
  @spec execute_job(String.t() | pid(), map()) :: {:ok, map()} | {:error, term()}
  def execute_job(poller, job) when is_binary(poller) do
    case lookup_pid(poller) do
      nil -> {:error, :poller_not_found}
      pid -> execute_job(pid, job)
    end
  end

  def execute_job(poller, job) when is_pid(poller) do
    GenServer.call(poller, {:execute_job, job}, 120_000)
  end

  @doc """
  Execute a job asynchronously.

  Returns immediately with a job_id. Results are broadcast via PubSub.
  """
  @spec execute_job_async(String.t() | pid(), map()) :: {:ok, String.t()} | {:error, term()}
  def execute_job_async(poller, job) when is_binary(poller) do
    case lookup_pid(poller) do
      nil -> {:error, :poller_not_found}
      pid -> execute_job_async(pid, job)
    end
  end

  def execute_job_async(poller, job) when is_pid(poller) do
    GenServer.call(poller, {:execute_job_async, job})
  end

  @doc """
  Get the current status of this poller.
  """
  @spec status(String.t() | pid()) :: {:ok, map()} | {:error, term()}
  def status(poller) when is_binary(poller) do
    case lookup_pid(poller) do
      nil -> {:error, :poller_not_found}
      pid -> status(pid)
    end
  end

  def status(poller) when is_pid(poller) do
    GenServer.call(poller, :status)
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    poller_id = Keyword.fetch!(opts, :poller_id)
    tenant_id = Keyword.fetch!(opts, :tenant_id)
    partition_id = Keyword.get(opts, :partition_id, "default")

    state = %{
      poller_id: poller_id,
      tenant_id: tenant_id,
      partition_id: partition_id,
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
    register_poller(state)

    # Schedule health checks
    schedule_health_check()

    Logger.info("Poller #{poller_id} started for tenant #{tenant_id}/#{partition_id}")

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
        "poller:results:#{state.poller_id}",
        {:job_result, job_id, result}
      )
    end)

    {:reply, {:ok, job_id}, state}
  end

  def handle_call(:status, _from, state) do
    status = %{
      poller_id: state.poller_id,
      tenant_id: state.tenant_id,
      partition_id: state.partition_id,
      status: state.status,
      metrics: state.metrics
    }

    {:reply, {:ok, status}, state}
  end

  @impl true
  def handle_info(:health_check, state) do
    # Update registry heartbeat
    PollerRegistry.heartbeat(state.poller_id)
    schedule_health_check()
    {:noreply, state}
  end

  @impl true
  def terminate(reason, state) do
    Logger.info("Poller #{state.poller_id} terminating: #{inspect(reason)}")
    PollerRegistry.unregister_poller(state.poller_id)
    :ok
  end

  # Private Functions

  defp via_tuple(poller_id) do
    {:via, Registry, {ServiceRadar.LocalRegistry, {:poller, poller_id}}}
  end

  defp lookup_pid(poller_id) do
    case Registry.lookup(ServiceRadar.LocalRegistry, {:poller, poller_id}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  defp register_poller(state) do
    poller_info = %{
      tenant_id: state.tenant_id,
      partition_id: state.partition_id,
      status: :idle
    }

    PollerRegistry.register_poller(state.poller_id, poller_info)
  end

  defp execute_job_impl(job, state) do
    checks = job[:checks] || []
    Logger.info("Poller #{state.poller_id} executing job with #{length(checks)} checks")

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
    agents = AgentRegistry.find_agents_for_partition(state.tenant_id, state.partition_id)

    # Filter to connected agents and pick one
    connected_agents =
      Enum.filter(agents, fn agent ->
        agent[:status] == :connected
      end)

    case connected_agents do
      [] -> nil
      # Simple load balancing
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
          poller_id: state.poller_id,
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
end
