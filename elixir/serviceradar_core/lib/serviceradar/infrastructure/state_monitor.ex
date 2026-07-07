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
        # Window a connected agent may leave a pushed config version unacknowledged
        # before it is marked config-unhealthy (default: 30 minutes)
        config_ack_timeout: 1_800_000,
        # Consecutive failures before marking checker as failing
        checker_failure_threshold: 3
  """

  use GenServer

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Infrastructure.Checker
  alias ServiceRadar.Infrastructure.Gateway
  alias ServiceRadar.Infrastructure.HealthTracker

  require Logger

  @default_check_interval to_timeout(second: 30)
  @default_gateway_timeout to_timeout(minute: 2)
  @default_agent_timeout to_timeout(minute: 5)
  @default_config_ack_timeout to_timeout(minute: 30)
  @default_checker_failure_threshold 3

  defstruct [
    :check_interval,
    :gateway_timeout,
    :agent_timeout,
    :config_ack_timeout,
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
      config_ack_timeout:
        Keyword.get(merged_opts, :config_ack_timeout, @default_config_ack_timeout),
      checker_failure_threshold:
        Keyword.get(merged_opts, :checker_failure_threshold, @default_checker_failure_threshold),
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
      config_ack_timeout: state.config_ack_timeout,
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
      Task.async(fn -> check_checkers(state, actor) end),
      Task.async(fn -> check_agent_config_health(state, actor) end)
    ]

    results = Task.await_many(tasks, to_timeout(second: 30))

    duration = System.monotonic_time(:millisecond) - start_time

    :telemetry.execute(
      [:serviceradar, :infrastructure, :state_monitor, :check_completed],
      %{duration: duration},
      %{
        gateways_checked: Enum.at(results, 0),
        agents_checked: Enum.at(results, 1),
        checkers_checked: Enum.at(results, 2),
        agents_config_checked: Enum.at(results, 3)
      }
    )

    Logger.debug("Health checks completed", duration_ms: duration)
  end

  defp check_gateways(state, actor) do
    timeout_threshold = DateTime.add(DateTime.utc_now(), -state.gateway_timeout, :millisecond)

    run_check(
      fn -> list_stale_gateways(timeout_threshold, actor) end,
      fn gateway -> handle_stale_gateway(gateway, actor) end,
      "gateways"
    )
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

    transition_resource(
      gateway,
      action,
      %{reason: "heartbeat_timeout"},
      actor,
      "gateway",
      gateway_id: gateway.id
    )
  end

  defp check_agents(state, actor) do
    timeout_threshold = DateTime.add(DateTime.utc_now(), -state.agent_timeout, :millisecond)

    run_check(
      fn -> list_stale_agents(timeout_threshold, actor) end,
      fn agent -> handle_stale_agent(agent, actor) end,
      "agents"
    )
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

    transition_resource(agent, :lose_connection, %{}, actor, "agent", agent_uid: agent.uid)
  end

  # ==========================================================================
  # Agent config health (wedge detection)
  # ==========================================================================

  # Evaluates config-apply health for connected agents and transitions
  # config_health on the agent record, emitting a health event + telemetry on
  # every wedge/clear transition:
  #
  #   - rule 1 (ack drift): the gateway pushed a config version the agent has not
  #     acknowledged within `config_ack_timeout` while remaining connected. The
  #     rule is anchored on the PUSHED version (not on ack staleness alone), so a
  #     quiet fleet with no config changes never false-positives. It also requires
  #     the push to still be OUTSTANDING — the agent must not have committed any
  #     version since the push was recorded (see `push_still_outstanding?/1`), so a
  #     stale proactive-push snapshot the agent skipped past by converging on a
  #     newer version via the poll path does not false-wedge (and flap) a healthy
  #     agent that is already running the version core currently generates.
  #   - rule 2 (permanent section): the agent's last sectioned ack reports a
  #     permanently failing config section.
  defp check_agent_config_health(state, actor) do
    require Ash.Query

    threshold = DateTime.add(DateTime.utc_now(), -state.config_ack_timeout, :millisecond)

    Agent
    |> Ash.Query.filter(status in [:connected, :degraded])
    |> Ash.read(actor: actor)
    |> case do
      {:ok, agents} ->
        Enum.each(agents, fn agent -> evaluate_agent_config_health(agent, threshold, actor) end)
        length(agents)

      {:error, reason} ->
        Logger.error("Failed to check agent config health", reason: inspect(reason))
        0
    end
  end

  @doc """
  Evaluates one agent's config-apply health against the no-ack threshold and
  transitions `config_health` (emitting health events + telemetry on change).
  Public for tests and on-demand tooling; the periodic check calls it per agent.
  """
  @spec evaluate_agent_config_health(struct(), DateTime.t(), term()) :: :ok
  def evaluate_agent_config_health(agent, threshold, actor) do
    case config_wedge_reason(agent, threshold) do
      nil -> maybe_clear_config_health(agent, actor)
      {reason, metadata} -> maybe_mark_config_unhealthy(agent, reason, metadata, actor)
    end

    :ok
  end

  @doc """
  Returns `nil` when an agent's config apply looks healthy, or `{reason, metadata}`
  describing why it is config-wedged. Pure — exposed for unit testing.
  """
  @spec config_wedge_reason(struct(), DateTime.t()) :: nil | {atom(), map()}
  def config_wedge_reason(agent, threshold) do
    permanent_section_wedge(agent) || unacked_push_wedge(agent, threshold)
  end

  defp permanent_section_wedge(agent) do
    case permanent_section_failure(agent) do
      nil ->
        nil

      failure ->
        {:config_section_permanent_failure,
         %{
           section: section_field(failure, "section"),
           error: section_field(failure, "error"),
           failing_since: section_field(failure, "since"),
           acked_config_version: agent.acked_config_version
         }}
    end
  end

  defp unacked_push_wedge(agent, threshold) do
    if unacked_push?(agent, threshold) do
      {:config_ack_timeout,
       %{
         pushed_config_version: agent.pushed_config_version,
         pushed_at: agent.config_pushed_at,
         acked_config_version: agent.acked_config_version,
         acked_at: agent.config_acked_at
       }}
    end
  end

  defp permanent_section_failure(agent) do
    agent.config_section_statuses
    |> List.wrap()
    |> Enum.find(fn status ->
      is_map(status) and section_field(status, "disposition") == "permanent_failure"
    end)
  end

  defp section_field(status, key) when is_map(status) do
    Map.get(status, key) || Map.get(status, section_atom_key(key))
  end

  defp section_atom_key("section"), do: :section
  defp section_atom_key("disposition"), do: :disposition
  defp section_atom_key("error"), do: :error
  defp section_atom_key("since"), do: :since

  defp unacked_push?(agent, threshold) do
    is_binary(agent.pushed_config_version) and agent.pushed_config_version != "" and
      agent.pushed_config_version != agent.acked_config_version and
      not is_nil(agent.config_pushed_at) and
      DateTime.before?(agent.config_pushed_at, threshold) and
      push_still_outstanding?(agent)
  end

  # A pushed version only counts as un-acked while it is still OUTSTANDING: the
  # agent must not have committed any config version since the push was recorded.
  #
  # `config_pushed_at` is anchored to a version's FIRST proactive control-stream
  # push. `config_acked_at` advances (debounced on the version) whenever the agent
  # reports a newly-committed version — including versions it converged on via the
  # config POLL path, which delivers the latest config but never updates
  # `pushed_config_version`. So `pushed_config_version` can freeze on a proactive-push
  # snapshot while the agent moves on to a newer version via poll, leaving
  # `pushed != acked` forever even though the agent runs exactly what core generates.
  #
  # If the agent acked at or after the push, it has committed a version more recent
  # than the pushed snapshot: the push is obsolete (superseded), not wedged. A
  # genuinely stuck agent never commits past the push — its committed version stays
  # frozen, so the debounced ack timestamp predates the push (or is absent).
  defp push_still_outstanding?(%{config_acked_at: nil}), do: true

  defp push_still_outstanding?(agent) do
    DateTime.before?(agent.config_acked_at, agent.config_pushed_at)
  end

  defp maybe_mark_config_unhealthy(%Agent{config_health: :unhealthy}, _reason, _metadata, _actor),
    do: :ok

  defp maybe_mark_config_unhealthy(agent, reason, metadata, actor) do
    Logger.warning("Agent config-unhealthy (wedged)",
      agent_uid: agent.uid,
      reason: reason,
      metadata: inspect(metadata)
    )

    transition_resource(
      agent,
      :set_config_health,
      %{config_health: :unhealthy},
      actor,
      "agent config health",
      agent_uid: agent.uid
    )

    HealthTracker.record_state_change(:agent, agent.uid,
      old_state: config_health_event_state(agent.config_health),
      new_state: :config_wedged,
      reason: reason,
      metadata: Map.put(metadata, :agent_uid, agent.uid)
    )

    :telemetry.execute(
      [:serviceradar, :agent_config, :wedged],
      %{count: 1},
      Map.merge(metadata, %{agent_uid: agent.uid, reason: reason})
    )
  end

  defp maybe_clear_config_health(%Agent{config_health: :unhealthy} = agent, actor) do
    Logger.info("Agent config health recovered", agent_uid: agent.uid)

    transition_resource(
      agent,
      :set_config_health,
      %{config_health: :healthy},
      actor,
      "agent config health",
      agent_uid: agent.uid
    )

    HealthTracker.record_state_change(:agent, agent.uid,
      old_state: :config_wedged,
      new_state: :config_healthy,
      reason: :config_recovered,
      metadata: %{agent_uid: agent.uid, acked_config_version: agent.acked_config_version}
    )

    :telemetry.execute(
      [:serviceradar, :agent_config, :cleared],
      %{count: 1},
      %{agent_uid: agent.uid, acked_config_version: agent.acked_config_version}
    )
  end

  defp maybe_clear_config_health(%Agent{config_health: :unknown} = agent, actor) do
    # First observation with config-ack data present: settle to healthy silently
    # (no health event — nothing recovered).
    if is_binary(agent.acked_config_version) or is_binary(agent.pushed_config_version) do
      transition_resource(
        agent,
        :set_config_health,
        %{config_health: :healthy},
        actor,
        "agent config health",
        agent_uid: agent.uid
      )
    end

    :ok
  end

  defp maybe_clear_config_health(_agent, _actor), do: :ok

  defp config_health_event_state(:unhealthy), do: :config_wedged
  defp config_health_event_state(:healthy), do: :config_healthy
  defp config_health_event_state(_), do: nil

  defp check_checkers(state, actor) do
    run_check(
      fn -> list_failing_checkers(state.checker_failure_threshold, actor) end,
      fn checker -> handle_failing_checker(checker, actor) end,
      "checkers"
    )
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

    transition_resource(
      checker,
      :mark_failing,
      %{reason: "consecutive_failures"},
      actor,
      "checker",
      checker_id: checker.id
    )
  end

  defp run_check(list_fun, handle_fun, resource_name) do
    case list_fun.() do
      {:ok, resources} ->
        Enum.each(resources, handle_fun)
        length(resources)

      {:error, reason} ->
        Logger.error("Failed to check #{resource_name}", reason: inspect(reason))
        0
    end
  end

  defp transition_resource(resource, action, params, actor, resource_name, metadata) do
    result =
      resource
      |> Ash.Changeset.for_update(action, params, actor: actor)
      |> Ash.update()

    case result do
      {:ok, _updated_resource} ->
        :ok

      {:error, reason} ->
        Logger.error(
          "Failed to transition #{resource_name}",
          Keyword.put(metadata, :reason, inspect(reason))
        )
    end
  end
end
