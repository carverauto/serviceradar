defmodule ServiceRadar.Infrastructure.StateMonitor do
  @moduledoc """
  Tenant-scoped GenServer that monitors infrastructure components and triggers state transitions.

  Each tenant has their own StateMonitor that periodically checks:
  - Gateways for heartbeat timeouts (last_seen)
  - Agents for reachability (last_seen_time)
  - Checkers for consecutive failures

  Uses Ash actions with PublishStateChange to record health events.

  ## Starting

  StateMonitor is automatically started when:
  - A gateway is created for a tenant
  - An agent is created for a tenant
  - Manually via `ensure_started/1`

  ## Configuration

      config :serviceradar_core, ServiceRadar.Infrastructure.StateMonitor,
        # How often to run health checks (default: 30 seconds)
        check_interval: 30_000,
        # Gateway heartbeat timeout (default: 2 minutes)
        gateway_timeout: 120_000,
        # Agent heartbeat timeout (default: 5 minutes)
        agent_timeout: 300_000,
        # Consecutive failures before marking checker as failing
        checker_failure_threshold: 3
  """

  use GenServer

  alias ServiceRadar.Cluster.TenantRegistry
  alias ServiceRadar.Infrastructure.{Gateway, Agent, Checker}

  require Logger

  @default_check_interval :timer.seconds(30)
  @default_gateway_timeout :timer.minutes(2)
  @default_agent_timeout :timer.minutes(5)
  @default_checker_failure_threshold 3

  defstruct [
    :tenant_id,
    :tenant_schema,
    :actor,
    :check_interval,
    :gateway_timeout,
    :agent_timeout,
    :checker_failure_threshold,
    :last_check,
    :check_timer
  ]

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Ensures StateMonitor is running for a tenant, starting it if necessary.
  """
  @spec ensure_started(String.t()) :: {:ok, pid()} | {:error, term()}
  def ensure_started(tenant_id) when is_binary(tenant_id) do
    case whereis(tenant_id) do
      nil ->
        start_for_tenant(tenant_id)

      pid ->
        {:ok, pid}
    end
  end

  @doc """
  Returns the PID of the StateMonitor for a tenant, or nil if not running.
  """
  @spec whereis(String.t()) :: pid() | nil
  def whereis(tenant_id) when is_binary(tenant_id) do
    case TenantRegistry.lookup(tenant_id, {:state_monitor, tenant_id}) do
      [{pid, _meta}] -> pid
      [] -> nil
    end
  end

  @doc """
  Starts StateMonitor for a tenant under the tenant's supervisor.
  """
  @spec start_for_tenant(String.t()) :: {:ok, pid()} | {:error, term()}
  def start_for_tenant(tenant_id) when is_binary(tenant_id) do
    child_spec = %{
      id: {:state_monitor, tenant_id},
      start: {__MODULE__, :start_link, [[tenant_id: tenant_id]]},
      type: :worker,
      restart: :transient
    }

    case TenantRegistry.start_child(tenant_id, child_spec) do
      {:ok, pid} ->
        Logger.info("Started StateMonitor for tenant", tenant_id: tenant_id)
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        {:ok, pid}

      {:error, reason} = error ->
        Logger.error("Failed to start StateMonitor",
          tenant_id: tenant_id,
          reason: inspect(reason)
        )

        error
    end
  end

  @doc """
  Triggers an immediate health check for a tenant.
  """
  @spec check_now(String.t()) :: :ok
  def check_now(tenant_id) when is_binary(tenant_id) do
    case whereis(tenant_id) do
      nil -> :ok
      pid -> GenServer.cast(pid, :check_now)
    end
  end

  @doc """
  Returns current monitoring status for a tenant.
  """
  @spec status(String.t()) :: map() | nil
  def status(tenant_id) when is_binary(tenant_id) do
    case whereis(tenant_id) do
      nil -> nil
      pid -> GenServer.call(pid, :status)
    end
  end

  # ============================================================================
  # GenServer Implementation
  # ============================================================================

  def start_link(opts) do
    tenant_id = Keyword.fetch!(opts, :tenant_id)
    GenServer.start_link(__MODULE__, opts, name: via_tuple(tenant_id))
  end

  defp via_tuple(tenant_id) do
    {:via, Horde.Registry, {TenantRegistry.registry_name(tenant_id), {:state_monitor, tenant_id}}}
  end

  @impl true
  def init(opts) do
    tenant_id = Keyword.fetch!(opts, :tenant_id)
    tenant_schema = Keyword.get(opts, :tenant_schema, tenant_id)

    config = Application.get_env(:serviceradar_core, __MODULE__, [])
    merged_opts = Keyword.merge(config, opts)

    state = %__MODULE__{
      tenant_id: tenant_id,
      tenant_schema: tenant_schema,
      actor: build_system_actor(tenant_id),
      check_interval: Keyword.get(merged_opts, :check_interval, @default_check_interval),
      gateway_timeout: Keyword.get(merged_opts, :gateway_timeout, @default_gateway_timeout),
      agent_timeout: Keyword.get(merged_opts, :agent_timeout, @default_agent_timeout),
      checker_failure_threshold: Keyword.get(merged_opts, :checker_failure_threshold, @default_checker_failure_threshold),
      last_check: nil
    }

    Logger.info("StateMonitor starting", tenant_id: tenant_id)

    # Schedule first check
    timer = schedule_check(state.check_interval)

    {:ok, %{state | check_timer: timer}}
  end

  @impl true
  def handle_call(:status, _from, state) do
    status = %{
      tenant_id: state.tenant_id,
      check_interval: state.check_interval,
      gateway_timeout: state.gateway_timeout,
      agent_timeout: state.agent_timeout,
      checker_failure_threshold: state.checker_failure_threshold,
      last_check: state.last_check,
      node: node()
    }

    {:reply, status, state}
  end

  @impl true
  def handle_cast(:check_now, state) do
    run_health_checks(state)
    {:noreply, %{state | last_check: DateTime.utc_now()}}
  end

  @impl true
  def handle_info(:run_checks, state) do
    run_health_checks(state)

    # Schedule next check
    timer = schedule_check(state.check_interval)

    {:noreply, %{state | last_check: DateTime.utc_now(), check_timer: timer}}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp schedule_check(interval) do
    Process.send_after(self(), :run_checks, interval)
  end

  defp run_health_checks(state) do
    Logger.debug("Running infrastructure health checks", tenant_id: state.tenant_id)

    start_time = System.monotonic_time(:millisecond)

    # Run checks in parallel
    tasks = [
      Task.async(fn -> check_gateways(state) end),
      Task.async(fn -> check_agents(state) end),
      Task.async(fn -> check_checkers(state) end)
    ]

    results = Task.await_many(tasks, :timer.seconds(30))

    duration = System.monotonic_time(:millisecond) - start_time

    :telemetry.execute(
      [:serviceradar, :infrastructure, :state_monitor, :check_completed],
      %{duration: duration},
      %{
        tenant_id: state.tenant_id,
        gateways_checked: Enum.at(results, 0),
        agents_checked: Enum.at(results, 1),
        checkers_checked: Enum.at(results, 2)
      }
    )

    Logger.debug("Health checks completed",
      tenant_id: state.tenant_id,
      duration_ms: duration
    )
  end

  defp check_gateways(state) do
    timeout_threshold = DateTime.add(DateTime.utc_now(), -state.gateway_timeout, :millisecond)

    case list_stale_gateways(timeout_threshold, state) do
      {:ok, gateways} ->
        Enum.each(gateways, fn gateway ->
          handle_stale_gateway(gateway, state)
        end)

        length(gateways)

      {:error, reason} ->
        Logger.error("Failed to check gateways",
          tenant_id: state.tenant_id,
          reason: inspect(reason)
        )

        0
    end
  end

  defp list_stale_gateways(timeout_threshold, state) do
    require Ash.Query

    Gateway
    |> Ash.Query.filter(
      status in [:healthy, :degraded] and
        (is_nil(last_seen) or last_seen < ^timeout_threshold)
    )
    |> Ash.read(actor: state.actor, tenant: state.tenant_schema)
  end

  defp handle_stale_gateway(gateway, state) do
    Logger.info("Gateway heartbeat timeout, transitioning to degraded/offline",
      tenant_id: state.tenant_id,
      gateway_id: gateway.id
    )

    old_state = gateway.status
    action = if old_state == :healthy, do: :degrade, else: :go_offline

    result =
      gateway
      |> Ash.Changeset.for_update(action, %{reason: "heartbeat_timeout"})
      |> Ash.update(actor: state.actor, tenant: state.tenant_schema)

    case result do
      {:ok, _updated_gateway} ->
        :ok

      {:error, reason} ->
        Logger.error("Failed to transition gateway",
          tenant_id: state.tenant_id,
          gateway_id: gateway.id,
          reason: inspect(reason)
        )
    end
  end

  defp check_agents(state) do
    timeout_threshold = DateTime.add(DateTime.utc_now(), -state.agent_timeout, :millisecond)

    case list_stale_agents(timeout_threshold, state) do
      {:ok, agents} ->
        Enum.each(agents, fn agent ->
          handle_stale_agent(agent, state)
        end)

        length(agents)

      {:error, reason} ->
        Logger.error("Failed to check agents",
          tenant_id: state.tenant_id,
          reason: inspect(reason)
        )

        0
    end
  end

  defp list_stale_agents(timeout_threshold, state) do
    require Ash.Query

    Agent
    |> Ash.Query.filter(
      status in [:connected, :degraded] and
        (is_nil(last_seen_time) or last_seen_time < ^timeout_threshold)
    )
    |> Ash.read(actor: state.actor, tenant: state.tenant_schema)
  end

  defp handle_stale_agent(agent, state) do
    Logger.info("Agent heartbeat timeout, transitioning to disconnected",
      tenant_id: state.tenant_id,
      agent_uid: agent.uid
    )

    result =
      agent
      |> Ash.Changeset.for_update(:lose_connection, %{})
      |> Ash.update(actor: state.actor, tenant: state.tenant_schema)

    case result do
      {:ok, _updated_agent} ->
        :ok

      {:error, reason} ->
        Logger.error("Failed to transition agent",
          tenant_id: state.tenant_id,
          agent_uid: agent.uid,
          reason: inspect(reason)
        )
    end
  end

  defp check_checkers(state) do
    case list_failing_checkers(state.checker_failure_threshold, state) do
      {:ok, checkers} ->
        Enum.each(checkers, fn checker ->
          handle_failing_checker(checker, state)
        end)

        length(checkers)

      {:error, reason} ->
        Logger.error("Failed to check checkers",
          tenant_id: state.tenant_id,
          reason: inspect(reason)
        )

        0
    end
  end

  defp list_failing_checkers(threshold, state) do
    require Ash.Query

    Checker
    |> Ash.Query.filter(
      status == :active and
        consecutive_failures >= ^threshold
    )
    |> Ash.read(actor: state.actor, tenant: state.tenant_schema)
  end

  defp handle_failing_checker(checker, state) do
    Logger.info("Checker has consecutive failures, marking as failing",
      tenant_id: state.tenant_id,
      checker_id: checker.id,
      consecutive_failures: checker.consecutive_failures
    )

    result =
      checker
      |> Ash.Changeset.for_update(:mark_failing, %{reason: "consecutive_failures"})
      |> Ash.update(actor: state.actor, tenant: state.tenant_schema)

    case result do
      {:ok, _updated_checker} ->
        :ok

      {:error, reason} ->
        Logger.error("Failed to transition checker",
          tenant_id: state.tenant_id,
          checker_id: checker.id,
          reason: inspect(reason)
        )
    end
  end

  defp build_system_actor(tenant_id) do
    %{
      id: "system",
      email: "state-monitor@serviceradar",
      role: :admin,
      tenant_id: tenant_id
    }
  end
end
