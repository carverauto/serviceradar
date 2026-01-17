defmodule ServiceRadar.Infrastructure.StateMonitor do
  @moduledoc """
  GenServer that monitors infrastructure components and triggers state transitions.

  Periodically checks:
  - Gateways for heartbeat timeouts (last_seen)
  - Agents for reachability (last_seen_time)
  - Checkers for consecutive failures

  Uses Ash actions with PublishStateChange to record health events.

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

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Infrastructure.{Agent, Checker, Gateway}

  require Logger

  @default_check_interval :timer.seconds(30)
  @default_gateway_timeout :timer.minutes(2)
  @default_agent_timeout :timer.minutes(5)
  @default_checker_failure_threshold 3

  defstruct [
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
  Returns the PID of the StateMonitor, or nil if not running.
  """
  @spec whereis() :: pid() | nil
  def whereis do
    GenServer.whereis(__MODULE__)
  end

  @doc """
  Triggers an immediate health check.
  """
  @spec check_now() :: :ok
  def check_now do
    case whereis() do
      nil -> :ok
      pid -> GenServer.cast(pid, :check_now)
    end
  end

  @doc """
  Returns current monitoring status.
  """
  @spec status() :: map() | nil
  def status do
    case whereis() do
      nil -> nil
      pid -> GenServer.call(pid, :status)
    end
  end

  # ============================================================================
  # GenServer Implementation
  # ============================================================================

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    config = Application.get_env(:serviceradar_core, __MODULE__, [])
    merged_opts = Keyword.merge(config, opts)

    state = %__MODULE__{
      check_interval: Keyword.get(merged_opts, :check_interval, @default_check_interval),
      gateway_timeout: Keyword.get(merged_opts, :gateway_timeout, @default_gateway_timeout),
      agent_timeout: Keyword.get(merged_opts, :agent_timeout, @default_agent_timeout),
      checker_failure_threshold: Keyword.get(merged_opts, :checker_failure_threshold, @default_checker_failure_threshold),
      last_check: nil
    }

    Logger.info("StateMonitor starting")

    # Schedule first check
    timer = schedule_check(state.check_interval)

    {:ok, %{state | check_timer: timer}}
  end

  @impl true
  def handle_call(:status, _from, state) do
    status = %{
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
    Logger.debug("Running infrastructure health checks")

    start_time = System.monotonic_time(:millisecond)

    # DB connection's search_path determines the schema
    actor = SystemActor.system(:state_monitor)

    # Run checks in parallel
    tasks = [
      Task.async(fn -> check_gateways(state, actor) end),
      Task.async(fn -> check_agents(state, actor) end),
      Task.async(fn -> check_checkers(state, actor) end)
    ]

    results = Task.await_many(tasks, :timer.seconds(30))

    duration = System.monotonic_time(:millisecond) - start_time

    :telemetry.execute(
      [:serviceradar, :infrastructure, :state_monitor, :check_completed],
      %{duration: duration},
      %{
        gateways_checked: Enum.at(results, 0),
        agents_checked: Enum.at(results, 1),
        checkers_checked: Enum.at(results, 2)
      }
    )

    Logger.debug("Health checks completed", duration_ms: duration)
  end

  defp check_gateways(state, actor) do
    timeout_threshold = DateTime.add(DateTime.utc_now(), -state.gateway_timeout, :millisecond)

    case list_stale_gateways(timeout_threshold, actor) do
      {:ok, gateways} ->
        Enum.each(gateways, fn gateway ->
          handle_stale_gateway(gateway, actor)
        end)

        length(gateways)

      {:error, reason} ->
        Logger.error("Failed to check gateways", reason: inspect(reason))
        0
    end
  end

  defp list_stale_gateways(timeout_threshold, actor) do
    require Ash.Query

    Gateway
    |> Ash.Query.filter(
      status in [:healthy, :degraded] and
        (is_nil(last_seen) or last_seen < ^timeout_threshold)
    )
    |> Ash.read(actor: actor)
  end

  defp handle_stale_gateway(gateway, actor) do
    Logger.info("Gateway heartbeat timeout, transitioning to degraded/offline",
      gateway_id: gateway.id
    )

    old_state = gateway.status
    action = if old_state == :healthy, do: :degrade, else: :go_offline

    result =
      gateway
      |> Ash.Changeset.for_update(action, %{reason: "heartbeat_timeout"}, actor: actor)
      |> Ash.update()

    case result do
      {:ok, _updated_gateway} ->
        :ok

      {:error, reason} ->
        Logger.error("Failed to transition gateway",
          gateway_id: gateway.id,
          reason: inspect(reason)
        )
    end
  end

  defp check_agents(state, actor) do
    timeout_threshold = DateTime.add(DateTime.utc_now(), -state.agent_timeout, :millisecond)

    case list_stale_agents(timeout_threshold, actor) do
      {:ok, agents} ->
        Enum.each(agents, fn agent ->
          handle_stale_agent(agent, actor)
        end)

        length(agents)

      {:error, reason} ->
        Logger.error("Failed to check agents", reason: inspect(reason))
        0
    end
  end

  defp list_stale_agents(timeout_threshold, actor) do
    require Ash.Query

    Agent
    |> Ash.Query.filter(
      status in [:connected, :degraded] and
        (is_nil(last_seen_time) or last_seen_time < ^timeout_threshold)
    )
    |> Ash.read(actor: actor)
  end

  defp handle_stale_agent(agent, actor) do
    Logger.info("Agent heartbeat timeout, transitioning to disconnected",
      agent_uid: agent.uid
    )

    result =
      agent
      |> Ash.Changeset.for_update(:lose_connection, %{}, actor: actor)
      |> Ash.update()

    case result do
      {:ok, _updated_agent} ->
        :ok

      {:error, reason} ->
        Logger.error("Failed to transition agent",
          agent_uid: agent.uid,
          reason: inspect(reason)
        )
    end
  end

  defp check_checkers(state, actor) do
    case list_failing_checkers(state.checker_failure_threshold, actor) do
      {:ok, checkers} ->
        Enum.each(checkers, fn checker ->
          handle_failing_checker(checker, actor)
        end)

        length(checkers)

      {:error, reason} ->
        Logger.error("Failed to check checkers", reason: inspect(reason))
        0
    end
  end

  defp list_failing_checkers(threshold, actor) do
    require Ash.Query

    Checker
    |> Ash.Query.filter(
      status == :active and
        consecutive_failures >= ^threshold
    )
    |> Ash.read(actor: actor)
  end

  defp handle_failing_checker(checker, actor) do
    Logger.info("Checker has consecutive failures, marking as failing",
      checker_id: checker.id,
      consecutive_failures: checker.consecutive_failures
    )

    result =
      checker
      |> Ash.Changeset.for_update(:mark_failing, %{reason: "consecutive_failures"}, actor: actor)
      |> Ash.update()

    case result do
      {:ok, _updated_checker} ->
        :ok

      {:error, reason} ->
        Logger.error("Failed to transition checker",
          checker_id: checker.id,
          reason: inspect(reason)
        )
    end
  end
end
