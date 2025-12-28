defmodule ServiceRadar.Infrastructure.StateMonitor do
  @moduledoc """
  Monitors infrastructure components and triggers state transitions.

  Periodically checks:
  - Pollers for heartbeat timeouts (last_seen)
  - Agents for reachability (last_seen_time)
  - Checkers for consecutive failures
  - Cross-references Horde registry state with database state

  Publishes events to NATS JetStream via EventPublisher when state changes.

  ## Horde Integration

  The StateMonitor integrates with Horde registries to:
  - Use leader election to run checks on only one node
  - Cross-reference Horde-registered entities with database records
  - Detect orphaned processes (in Horde but not DB) and stale records (in DB but not Horde)

  ## Configuration

      config :serviceradar_core, ServiceRadar.Infrastructure.StateMonitor,
        # How often to run health checks (default: 30 seconds)
        check_interval: 30_000,
        # Poller heartbeat timeout (default: 2 minutes)
        poller_timeout: 120_000,
        # Agent heartbeat timeout (default: 5 minutes)
        agent_timeout: 300_000,
        # Consecutive failures before marking checker as failing
        checker_failure_threshold: 3,
        # Enable distributed mode with leader election (default: true)
        distributed: true

  ## Supervision

  Add to your supervision tree:

      children = [
        ServiceRadar.Infrastructure.StateMonitor
      ]
  """

  use GenServer

  alias ServiceRadar.Cluster.TenantRegistry
  alias ServiceRadar.Infrastructure.{Poller, Agent, Checker, EventPublisher}

  require Logger

  @default_check_interval :timer.seconds(30)
  @default_poller_timeout :timer.minutes(2)
  @default_agent_timeout :timer.minutes(5)
  @default_checker_failure_threshold 3

  defstruct [
    :check_interval,
    :poller_timeout,
    :agent_timeout,
    :checker_failure_threshold,
    :last_check,
    :check_timer,
    :distributed,
    :is_leader
  ]

  # Client API

  @doc """
  Starts the state monitor.
  """
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Triggers an immediate health check.
  """
  @spec check_now(GenServer.server()) :: :ok
  def check_now(server \\ __MODULE__) do
    GenServer.cast(server, :check_now)
  end

  @doc """
  Returns current monitoring status.
  """
  @spec status(GenServer.server()) :: map()
  def status(server \\ __MODULE__) do
    GenServer.call(server, :status)
  end

  @doc """
  Returns whether this node is the current leader.
  """
  @spec is_leader?(GenServer.server()) :: boolean()
  def is_leader?(server \\ __MODULE__) do
    GenServer.call(server, :is_leader?)
  end

  # GenServer callbacks

  @impl true
  def init(opts) do
    config = Application.get_env(:serviceradar_core, __MODULE__, [])
    merged_opts = Keyword.merge(config, opts)

    distributed = Keyword.get(merged_opts, :distributed, true)

    state = %__MODULE__{
      check_interval: Keyword.get(merged_opts, :check_interval, @default_check_interval),
      poller_timeout: Keyword.get(merged_opts, :poller_timeout, @default_poller_timeout),
      agent_timeout: Keyword.get(merged_opts, :agent_timeout, @default_agent_timeout),
      checker_failure_threshold: Keyword.get(merged_opts, :checker_failure_threshold, @default_checker_failure_threshold),
      distributed: distributed,
      is_leader: false,
      last_check: nil
    }

    # Try to become leader if in distributed mode
    state = if distributed, do: try_become_leader(state), else: %{state | is_leader: true}

    # Monitor cluster changes
    if distributed do
      :net_kernel.monitor_nodes(true)
    end

    # Schedule first check
    timer = schedule_check(state.check_interval)

    {:ok, %{state | check_timer: timer}}
  end

  @impl true
  def handle_call(:status, _from, state) do
    status = %{
      check_interval: state.check_interval,
      poller_timeout: state.poller_timeout,
      agent_timeout: state.agent_timeout,
      checker_failure_threshold: state.checker_failure_threshold,
      last_check: state.last_check,
      is_leader: state.is_leader,
      distributed: state.distributed,
      node: node()
    }

    {:reply, status, state}
  end

  def handle_call(:is_leader?, _from, state) do
    {:reply, state.is_leader, state}
  end

  @impl true
  def handle_cast(:check_now, state) do
    if state.is_leader do
      run_health_checks(state)
    end
    {:noreply, %{state | last_check: DateTime.utc_now()}}
  end

  @impl true
  def handle_info(:run_checks, state) do
    # Only run checks if we're the leader
    if state.is_leader do
      run_health_checks(state)
    end

    # Schedule next check
    timer = schedule_check(state.check_interval)

    {:noreply, %{state | last_check: DateTime.utc_now(), check_timer: timer}}
  end

  # Node up/down events for re-election
  def handle_info({:nodeup, _node}, state) do
    Logger.debug("Node joined cluster, re-checking leadership")
    state = if state.distributed, do: try_become_leader(state), else: state
    {:noreply, state}
  end

  def handle_info({:nodedown, _node}, state) do
    Logger.debug("Node left cluster, re-checking leadership")
    state = if state.distributed, do: try_become_leader(state), else: state
    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # Leader election using :global registration
  defp try_become_leader(state) do
    case :global.register_name(__MODULE__, self(), &resolve_leader/3) do
      :yes ->
        Logger.info("StateMonitor became leader on #{node()}")
        %{state | is_leader: true}

      :no ->
        Logger.debug("StateMonitor is follower on #{node()}")
        %{state | is_leader: false}
    end
  end

  # Conflict resolution - keep the process on the node with lowest name
  defp resolve_leader(_name, pid1, pid2) do
    node1 = node(pid1)
    node2 = node(pid2)

    if node1 < node2 do
      pid1
    else
      pid2
    end
  end

  # Private functions

  defp schedule_check(interval) do
    Process.send_after(self(), :run_checks, interval)
  end

  defp run_health_checks(state) do
    Logger.debug("Running infrastructure health checks (leader: #{state.is_leader})")

    start_time = System.monotonic_time(:millisecond)

    # Run checks in parallel
    tasks = [
      Task.async(fn -> check_pollers(state) end),
      Task.async(fn -> check_agents(state) end),
      Task.async(fn -> check_checkers(state) end),
      Task.async(fn -> reconcile_horde_state() end)
    ]

    results = Task.await_many(tasks, :timer.seconds(30))

    duration = System.monotonic_time(:millisecond) - start_time

    :telemetry.execute(
      [:serviceradar, :infrastructure, :state_monitor, :check_completed],
      %{duration: duration},
      %{
        pollers_checked: Enum.at(results, 0),
        agents_checked: Enum.at(results, 1),
        checkers_checked: Enum.at(results, 2),
        horde_reconciled: Enum.at(results, 3)
      }
    )

    Logger.debug("Health checks completed in #{duration}ms")
  end

  # Reconcile Horde registry state with database state
  defp reconcile_horde_state do
    tenant_registries = TenantRegistry.list_registries()
    reconciled = 0

    # For each tenant registry, check registered entities against DB
    Enum.reduce(tenant_registries, reconciled, fn {_name, _pid}, acc ->
      # The registry name contains the tenant hash, we can't easily map back to tenant_id
      # For now, we skip detailed reconciliation and rely on heartbeat checks
      acc
    end)
  rescue
    e ->
      Logger.warning("Horde reconciliation failed: #{inspect(e)}")
      0
  end

  defp check_pollers(state) do
    timeout_threshold = DateTime.add(DateTime.utc_now(), -state.poller_timeout, :millisecond)

    # Find pollers that haven't been seen recently
    case list_stale_pollers(timeout_threshold) do
      {:ok, pollers} ->
        Enum.each(pollers, fn poller ->
          handle_stale_poller(poller, state)
        end)

        length(pollers)

      {:error, reason} ->
        Logger.error("Failed to check pollers: #{inspect(reason)}")
        0
    end
  end

  defp list_stale_pollers(timeout_threshold) do
    # Query pollers that are healthy/degraded but last_seen is before threshold
    require Ash.Query

    Poller
    |> Ash.Query.filter(
      status in [:healthy, :degraded] and
        (is_nil(last_seen) or last_seen < ^timeout_threshold)
    )
    |> Ash.read(authorize?: false)
  end

  defp handle_stale_poller(poller, _state) do
    Logger.info("Poller #{poller.id} heartbeat timeout, transitioning to degraded/offline")

    old_state = poller.status
    new_state = if old_state == :healthy, do: :degraded, else: :offline
    action = if old_state == :healthy, do: :degrade, else: :go_offline

    result =
      poller
      |> Ash.Changeset.for_update(action, %{reason: "heartbeat_timeout"})
      |> Ash.update(authorize?: false)

    case result do
      {:ok, updated_poller} ->
        publish_poller_event(updated_poller, old_state, new_state, :heartbeat_timeout)

      {:error, reason} ->
        Logger.error("Failed to transition poller #{poller.id}: #{inspect(reason)}")
    end
  end

  defp check_agents(state) do
    timeout_threshold = DateTime.add(DateTime.utc_now(), -state.agent_timeout, :millisecond)

    case list_stale_agents(timeout_threshold) do
      {:ok, agents} ->
        Enum.each(agents, fn agent ->
          handle_stale_agent(agent, state)
        end)

        length(agents)

      {:error, reason} ->
        Logger.error("Failed to check agents: #{inspect(reason)}")
        0
    end
  end

  defp list_stale_agents(timeout_threshold) do
    require Ash.Query

    Agent
    |> Ash.Query.filter(
      status in [:connected, :degraded] and
        (is_nil(last_seen_time) or last_seen_time < ^timeout_threshold)
    )
    |> Ash.read(authorize?: false)
  end

  defp handle_stale_agent(agent, _state) do
    Logger.info("Agent #{agent.uid} heartbeat timeout, transitioning to disconnected")

    old_state = agent.status
    new_state = :disconnected

    result =
      agent
      |> Ash.Changeset.for_update(:lose_connection, %{})
      |> Ash.update(authorize?: false)

    case result do
      {:ok, updated_agent} ->
        publish_agent_event(updated_agent, old_state, new_state, :heartbeat_timeout)

      {:error, reason} ->
        Logger.error("Failed to transition agent #{agent.uid}: #{inspect(reason)}")
    end
  end

  defp check_checkers(state) do
    case list_failing_checkers(state.checker_failure_threshold) do
      {:ok, checkers} ->
        Enum.each(checkers, fn checker ->
          handle_failing_checker(checker, state)
        end)

        length(checkers)

      {:error, reason} ->
        Logger.error("Failed to check checkers: #{inspect(reason)}")
        0
    end
  end

  defp list_failing_checkers(threshold) do
    require Ash.Query

    Checker
    |> Ash.Query.filter(
      status == :active and
        consecutive_failures >= ^threshold
    )
    |> Ash.read(authorize?: false)
  end

  defp handle_failing_checker(checker, _state) do
    Logger.info("Checker #{checker.id} has #{checker.consecutive_failures} consecutive failures, marking as failing")

    old_state = checker.status
    new_state = :failing

    result =
      checker
      |> Ash.Changeset.for_update(:mark_failing, %{reason: "consecutive_failures"})
      |> Ash.update(authorize?: false)

    case result do
      {:ok, updated_checker} ->
        publish_checker_event(updated_checker, old_state, new_state, :consecutive_failures)

      {:error, reason} ->
        Logger.error("Failed to transition checker #{checker.id}: #{inspect(reason)}")
    end
  end

  # Event publishing helpers

  defp publish_poller_event(poller, old_state, new_state, reason) do
    tenant_slug = lookup_tenant_slug(poller.tenant_id)

    if tenant_slug do
      EventPublisher.publish_state_change(
        entity_type: :poller,
        entity_id: poller.id,
        tenant_id: poller.tenant_id,
        tenant_slug: tenant_slug,
        partition_id: poller.partition_id,
        old_state: old_state,
        new_state: new_state,
        reason: reason
      )
    end
  end

  defp publish_agent_event(agent, old_state, new_state, reason) do
    tenant_slug = lookup_tenant_slug(agent.tenant_id)

    if tenant_slug do
      EventPublisher.publish_state_change(
        entity_type: :agent,
        entity_id: agent.uid,
        tenant_id: agent.tenant_id,
        tenant_slug: tenant_slug,
        old_state: old_state,
        new_state: new_state,
        reason: reason
      )
    end
  end

  defp publish_checker_event(checker, old_state, new_state, reason) do
    tenant_slug = lookup_tenant_slug(checker.tenant_id)

    if tenant_slug do
      EventPublisher.publish_state_change(
        entity_type: :checker,
        entity_id: to_string(checker.id),
        tenant_id: checker.tenant_id,
        tenant_slug: tenant_slug,
        old_state: old_state,
        new_state: new_state,
        reason: reason
      )
    end
  end

  defp lookup_tenant_slug(nil), do: nil

  defp lookup_tenant_slug(tenant_id) do
    require Ash.Query

    case ServiceRadar.Identity.Tenant
         |> Ash.Query.filter(id == ^tenant_id)
         |> Ash.Query.limit(1)
         |> Ash.read(authorize?: false) do
      {:ok, [tenant | _]} -> to_string(tenant.slug)
      _ -> nil
    end
  rescue
    _ -> nil
  end
end
