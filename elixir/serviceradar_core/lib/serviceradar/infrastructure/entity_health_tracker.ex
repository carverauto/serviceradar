defmodule ServiceRadar.Infrastructure.EntityHealthTracker do
  @moduledoc """
  Unified health tracking and recovery system for all infrastructure entities.

  Handles health monitoring, state transitions, and recovery for:
  - Pollers (job orchestrators)
  - Agents (check executors)
  - Checkers (service check definitions)
  - Collectors (data aggregation points)

  ## Overview

  The EntityHealthTracker provides:
  1. **Health Status Tracking** - Monitors heartbeat/last_seen timestamps
  2. **State Transitions** - Triggers degraded/offline transitions on timeout
  3. **Recovery Attempts** - Schedules and executes recovery workflows
  4. **Telemetry Metrics** - Tracks recovery time, success rate, health status

  ## Entity Types

  Each entity type has its own:
  - Timeout threshold (how long before considered unhealthy)
  - Recovery strategy (how to attempt recovery)
  - State machine transitions

  ## Configuration

      config :serviceradar_core, ServiceRadar.Infrastructure.EntityHealthTracker,
        # Timeouts per entity type (milliseconds)
        timeouts: %{
          poller: 120_000,    # 2 minutes
          agent: 300_000,     # 5 minutes
          checker: 180_000,   # 3 minutes
          collector: 120_000  # 2 minutes
        },
        # Max recovery attempts before marking offline
        max_recovery_attempts: 3,
        # Retry interval between recovery attempts
        retry_interval: 30_000,
        # Enable automatic recovery
        auto_recover: true

  ## Usage

      # Check entity health and trigger transitions if needed
      EntityHealthTracker.check_health(:poller, "poller-001", tenant_id)

      # Attempt recovery for an entity
      EntityHealthTracker.attempt_recovery(:agent, "agent-uid", tenant_id)

      # Schedule a recovery job
      EntityHealthTracker.schedule_recovery(:checker, checker_id, tenant_id)

      # Get health status summary
      EntityHealthTracker.health_summary(tenant_id)
  """

  alias ServiceRadar.Infrastructure.{Poller, Agent, Checker, EventPublisher}

  require Ash.Query
  require Logger

  @default_timeouts %{
    poller: :timer.minutes(2),
    agent: :timer.minutes(5),
    checker: :timer.minutes(3),
    collector: :timer.minutes(2)
  }

  @default_max_recovery_attempts 3
  @default_retry_interval :timer.seconds(30)

  @entity_modules %{
    poller: Poller,
    agent: Agent,
    checker: Checker
  }

  @entity_id_fields %{
    poller: :id,
    agent: :uid,
    checker: :id
  }

  @entity_timestamp_fields %{
    poller: :last_seen,
    agent: :last_seen_time,
    checker: :last_success
  }

  # Client API

  @doc """
  Checks health of a specific entity and triggers state transitions if needed.

  Returns:
  - `{:ok, :healthy}` - Entity is healthy
  - `{:ok, :degraded}` - Entity was transitioned to degraded
  - `{:ok, :offline}` - Entity was transitioned to offline
  - `{:ok, :unchanged}` - Entity already in appropriate state
  - `{:error, reason}` - Check failed
  """
  @spec check_health(atom(), String.t(), String.t() | nil) :: {:ok, atom()} | {:error, term()}
  def check_health(entity_type, entity_id, tenant_id) do
    with {:ok, entity} <- get_entity(entity_type, entity_id, tenant_id),
         {:ok, result} <- evaluate_health(entity_type, entity) do
      {:ok, result}
    end
  end

  @doc """
  Attempts recovery for a degraded or offline entity.

  Returns:
  - `{:ok, :recovered}` - Entity successfully recovered
  - `{:ok, :recovery_started}` - Recovery process initiated
  - `{:ok, :max_attempts_reached}` - Recovery failed, max attempts exhausted
  - `{:ok, :already_healthy}` - Entity doesn't need recovery
  - `{:error, reason}` - Recovery attempt failed
  """
  @spec attempt_recovery(atom(), String.t(), String.t() | nil, keyword()) ::
          {:ok, atom()} | {:error, term()}
  def attempt_recovery(entity_type, entity_id, tenant_id, opts \\ []) do
    start_time = System.monotonic_time(:millisecond)

    result = do_attempt_recovery(entity_type, entity_id, tenant_id, opts)

    duration = System.monotonic_time(:millisecond) - start_time

    :telemetry.execute(
      [:serviceradar, :infrastructure, :health_tracker, :recovery_attempt],
      %{duration: duration},
      %{
        entity_type: entity_type,
        entity_id: entity_id,
        tenant_id: tenant_id,
        result: elem(result, 1)
      }
    )

    result
  end

  @doc """
  Schedules a recovery attempt via Oban.
  """
  @spec schedule_recovery(atom(), String.t(), String.t() | nil, keyword()) ::
          {:ok, Oban.Job.t()} | {:error, term()}
  def schedule_recovery(entity_type, entity_id, tenant_id, opts \\ []) do
    delay = Keyword.get(opts, :delay, config(:retry_interval))
    attempt = Keyword.get(opts, :attempt, 1)

    %{
      entity_type: to_string(entity_type),
      entity_id: entity_id,
      tenant_id: tenant_id,
      attempt: attempt
    }
    |> ServiceRadar.Infrastructure.EntityHealthTracker.RecoveryWorker.new(
      scheduled_in: delay,
      queue: :entity_recovery
    )
    |> Oban.insert()
  end

  @doc """
  Returns a health summary for all entity types.
  """
  @spec health_summary(String.t() | nil) :: {:ok, map()} | {:error, term()}
  def health_summary(tenant_id) do
    summaries =
      @entity_modules
      |> Map.keys()
      |> Enum.map(fn entity_type ->
        {entity_type, get_type_summary(entity_type, tenant_id)}
      end)
      |> Map.new()

    {:ok, summaries}
  end

  @doc """
  Checks all entities of a given type for health issues.

  Used by StateMonitor for periodic health scans.
  """
  @spec scan_entity_type(atom(), String.t() | nil) :: {:ok, map()} | {:error, term()}
  def scan_entity_type(entity_type, tenant_id) do
    timeout = get_timeout(entity_type)
    threshold = DateTime.add(DateTime.utc_now(), -timeout, :millisecond)

    case list_stale_entities(entity_type, threshold, tenant_id) do
      {:ok, entities} ->
        results =
          Enum.map(entities, fn entity ->
            entity_id = get_entity_id(entity_type, entity)
            result = handle_stale_entity(entity_type, entity)
            {entity_id, result}
          end)

        healthy_count = Enum.count(results, fn {_, r} -> r == :healthy end)
        transitioned = Enum.count(results, fn {_, r} -> r in [:degraded, :offline] end)
        errors = Enum.count(results, fn {_, r} -> match?({:error, _}, r) end)

        {:ok, %{
          entity_type: entity_type,
          checked: length(results),
          healthy: healthy_count,
          transitioned: transitioned,
          errors: errors
        }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Private Implementation

  defp do_attempt_recovery(entity_type, entity_id, tenant_id, opts) do
    case get_entity(entity_type, entity_id, tenant_id) do
      {:ok, nil} ->
        {:error, :entity_not_found}

      {:ok, entity} ->
        current_status = Map.get(entity, :status)
        attempt_entity_recovery(entity_type, entity, current_status, opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp attempt_entity_recovery(_entity_type, _entity, status, _opts) when status in [:healthy, :active, :connected] do
    {:ok, :already_healthy}
  end

  defp attempt_entity_recovery(entity_type, entity, status, opts) when status in [:degraded, :offline, :failing, :disconnected] do
    max_attempts = Keyword.get(opts, :max_attempts, config(:max_recovery_attempts))
    current_attempt = Keyword.get(opts, :attempt, 1)

    entity_id = get_entity_id(entity_type, entity)
    tenant_id = Map.get(entity, :tenant_id)

    if current_attempt > max_attempts do
      Logger.warning("#{entity_type} #{entity_id} recovery failed after #{max_attempts} attempts")
      {:ok, :max_attempts_reached}
    else
      # Check if entity has recent activity (heartbeat)
      if entity_is_responsive?(entity_type, entity) do
        restore_entity_health(entity_type, entity)
      else
        # Start recovery process
        case start_recovery(entity_type, entity) do
          {:ok, _} ->
            schedule_recovery(entity_type, entity_id, tenant_id,
              delay: config(:retry_interval),
              attempt: current_attempt + 1
            )
            {:ok, :recovery_started}

          {:error, reason} ->
            {:error, reason}
        end
      end
    end
  end

  defp attempt_entity_recovery(_entity_type, _entity, status, _opts) do
    # Cannot recover from states like :inactive, :maintenance, :draining, :disabled
    {:ok, {:skip, status}}
  end

  defp entity_is_responsive?(entity_type, entity) do
    timestamp_field = Map.get(@entity_timestamp_fields, entity_type, :last_seen)
    last_activity = Map.get(entity, timestamp_field)

    case last_activity do
      nil -> false
      timestamp ->
        # Consider responsive if activity in last 2 minutes
        threshold = DateTime.add(DateTime.utc_now(), -:timer.minutes(2), :millisecond)
        DateTime.compare(timestamp, threshold) == :gt
    end
  end

  defp start_recovery(entity_type, entity) do
    action = recovery_action(entity_type)
    entity_id = get_entity_id(entity_type, entity)

    Logger.info("Starting recovery for #{entity_type} #{entity_id}")

    entity
    |> Ash.Changeset.for_update(action, %{})
    |> Ash.update(authorize?: false)
  end

  defp restore_entity_health(entity_type, entity) do
    action = restore_action(entity_type)
    entity_id = get_entity_id(entity_type, entity)

    Logger.info("Restoring health for #{entity_type} #{entity_id}")

    case entity
         |> Ash.Changeset.for_update(action, %{})
         |> Ash.update(authorize?: false) do
      {:ok, updated} ->
        publish_recovery_event(entity_type, updated)
        {:ok, :recovered}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp recovery_action(:poller), do: :recover
  defp recovery_action(:agent), do: :start_recovery
  defp recovery_action(:checker), do: :clear_failure
  defp recovery_action(_), do: :recover

  defp restore_action(:poller), do: :restore_health
  defp restore_action(:agent), do: :restore_health
  defp restore_action(:checker), do: :clear_failure
  defp restore_action(_), do: :restore_health

  defp evaluate_health(entity_type, entity) do
    timeout = get_timeout(entity_type)
    threshold = DateTime.add(DateTime.utc_now(), -timeout, :millisecond)

    timestamp_field = Map.get(@entity_timestamp_fields, entity_type, :last_seen)
    last_seen = Map.get(entity, timestamp_field)

    current_status = Map.get(entity, :status)

    cond do
      current_status in [:healthy, :active, :connected] and is_stale?(last_seen, threshold) ->
        handle_stale_entity(entity_type, entity)

      current_status in [:healthy, :active, :connected] ->
        {:ok, :healthy}

      true ->
        {:ok, :unchanged}
    end
  end

  defp is_stale?(nil, _threshold), do: true
  defp is_stale?(timestamp, threshold), do: DateTime.compare(timestamp, threshold) == :lt

  defp handle_stale_entity(entity_type, entity) do
    current_status = Map.get(entity, :status)
    entity_id = get_entity_id(entity_type, entity)

    {new_status, action} = determine_transition(entity_type, current_status)

    if action do
      Logger.info("#{entity_type} #{entity_id} heartbeat timeout: #{current_status} -> #{new_status}")

      case entity
           |> Ash.Changeset.for_update(action, %{})
           |> Ash.update(authorize?: false) do
        {:ok, _} -> {:ok, new_status}
        {:error, reason} -> {:error, reason}
      end
    else
      {:ok, :unchanged}
    end
  end

  # State transition mappings per entity type
  defp determine_transition(:poller, :healthy), do: {:degraded, :degrade}
  defp determine_transition(:poller, :degraded), do: {:offline, :go_offline}
  defp determine_transition(:agent, :connected), do: {:degraded, :degrade}
  defp determine_transition(:agent, :degraded), do: {:disconnected, :lose_connection}
  defp determine_transition(:checker, :active), do: {:failing, :mark_failing}
  defp determine_transition(_, _), do: {nil, nil}

  # Database Queries

  defp get_entity(:poller, entity_id, _tenant_id) do
    Poller
    |> Ash.Query.filter(id == ^entity_id)
    |> Ash.Query.limit(1)
    |> Ash.read(authorize?: false)
    |> normalize_single_result()
  end

  defp get_entity(:agent, entity_id, _tenant_id) do
    Agent
    |> Ash.Query.filter(uid == ^entity_id)
    |> Ash.Query.limit(1)
    |> Ash.read(authorize?: false)
    |> normalize_single_result()
  end

  defp get_entity(:checker, entity_id, _tenant_id) do
    Checker
    |> Ash.Query.filter(id == ^entity_id)
    |> Ash.Query.limit(1)
    |> Ash.read(authorize?: false)
    |> normalize_single_result()
  end

  defp get_entity(_entity_type, _entity_id, _tenant_id) do
    {:error, :unknown_entity_type}
  end

  defp normalize_single_result({:ok, [entity]}), do: {:ok, entity}
  defp normalize_single_result({:ok, []}), do: {:ok, nil}
  defp normalize_single_result({:error, reason}), do: {:error, reason}

  defp list_stale_entities(:poller, threshold, _tenant_id) do
    Poller
    |> Ash.Query.filter(
      status in [:healthy, :degraded] and
        (is_nil(last_seen) or last_seen < ^threshold)
    )
    |> Ash.read(authorize?: false)
  end

  defp list_stale_entities(:agent, threshold, _tenant_id) do
    Agent
    |> Ash.Query.filter(
      status in [:connected, :degraded] and
        (is_nil(last_seen_time) or last_seen_time < ^threshold)
    )
    |> Ash.read(authorize?: false)
  end

  defp list_stale_entities(:checker, threshold, _tenant_id) do
    Checker
    |> Ash.Query.filter(
      status == :active and
        (is_nil(last_success) or last_success < ^threshold)
    )
    |> Ash.read(authorize?: false)
  end

  defp list_stale_entities(_entity_type, _threshold, _tenant_id) do
    {:error, :unknown_entity_type}
  end

  defp get_type_summary(entity_type, _tenant_id) do
    module = Map.get(@entity_modules, entity_type)

    if module do
      case Ash.read(module, authorize?: false) do
        {:ok, entities} ->
          by_status =
            entities
            |> Enum.group_by(& &1.status)
            |> Enum.map(fn {status, list} -> {status, length(list)} end)
            |> Map.new()

          %{
            total: length(entities),
            by_status: by_status
          }

        {:error, _} ->
          %{total: 0, by_status: %{}, error: true}
      end
    else
      %{total: 0, by_status: %{}, error: :unknown_type}
    end
  end

  defp get_entity_id(entity_type, entity) do
    id_field = Map.get(@entity_id_fields, entity_type, :id)
    Map.get(entity, id_field)
  end

  # Event Publishing

  defp publish_recovery_event(entity_type, entity) do
    entity_id = get_entity_id(entity_type, entity)
    tenant_id = Map.get(entity, :tenant_id)
    tenant_slug = lookup_tenant_slug(tenant_id)

    if tenant_slug do
      EventPublisher.publish_state_change(
        entity_type: entity_type,
        entity_id: entity_id,
        tenant_id: tenant_id,
        tenant_slug: tenant_slug,
        old_state: :recovering,
        new_state: Map.get(entity, :status),
        reason: :recovery_complete,
        metadata: %{recovery_time: DateTime.utc_now()}
      )
    end
  end

  defp lookup_tenant_slug(nil), do: nil

  defp lookup_tenant_slug(tenant_id) do
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

  # Configuration

  defp get_timeout(entity_type) do
    timeouts = config(:timeouts)
    Map.get(timeouts, entity_type, Map.get(@default_timeouts, entity_type, :timer.minutes(2)))
  end

  defp config(key) do
    config = Application.get_env(:serviceradar_core, __MODULE__, [])

    case key do
      :timeouts -> Keyword.get(config, :timeouts, @default_timeouts)
      :max_recovery_attempts -> Keyword.get(config, :max_recovery_attempts, @default_max_recovery_attempts)
      :retry_interval -> Keyword.get(config, :retry_interval, @default_retry_interval)
      :auto_recover -> Keyword.get(config, :auto_recover, true)
    end
  end
end
