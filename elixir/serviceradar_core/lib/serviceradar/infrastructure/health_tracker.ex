defmodule ServiceRadar.Infrastructure.HealthTracker do
  @moduledoc """
  Unified health tracking API for all infrastructure entities.

  All health status changes flow through this module to create HealthEvents,
  regardless of the source:

  - **State machine transitions** - Gateways, Agents, Checkers (via PublishStateChange)
  - **gRPC health checks** - External services checked by Go agents
  - **Service heartbeats** - Core, Web, and other Elixir services self-reporting
  - **Manual updates** - Admin/operator actions

  Health events are persisted to `health_events`, published as `logs.internal.*`
  payloads on NATS for promotion, and broadcast via PubSub topics.

  ## Architecture

      ┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
      │  State Machine  │     │   gRPC Health   │     │    Heartbeat    │
      │  Transitions    │     │   from Agents   │     │   Self-Report   │
      └────────┬────────┘     └────────┬────────┘     └────────┬────────┘
               │                       │                       │
               └───────────────────────┼───────────────────────┘
                                       │
                                       ▼
                           ┌───────────────────────┐
                           │    HealthTracker      │
                           │  (this module)        │
                           └───────────┬───────────┘
                                       │
                           ┌───────────┴───────────┐
                           │                       │
                           ▼                       ▼
                   ┌───────────────┐       ┌───────────────┐
                   │  HealthEvent  │       │   PubSub      │
                   │  (database)   │       │  (real-time)  │
                   └───────────────┘       └───────────────┘
                           │
                           ▼
                   ┌───────────────┐
                   │ Internal Logs │
                   │   (NATS)      │
                   └───────────────┘

  ## Usage

      # Record a state change from any source
      HealthTracker.record_state_change(:agent, "agent-uid",
        old_state: :connected,
        new_state: :degraded,
        reason: :high_latency
      )

      # Record health check result from gRPC
      HealthTracker.record_health_check(:datasvc, "datasvc-node-1",
        healthy: false,
        latency_ms: 5000,
        error: "timeout"
      )

      # Record service heartbeat
      HealthTracker.heartbeat(:core, node_id,
        healthy: true,
        metadata: %{version: "1.0.0", uptime_seconds: 3600}
      )

      # Query health status
      HealthTracker.current_status(:gateway, "gateway-001")
      HealthTracker.timeline(:agent, "agent-uid", hours: 24)
      HealthTracker.summary()
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Events.HealthWriter
  alias ServiceRadar.Infrastructure.HealthEvent
  alias ServiceRadar.Infrastructure.HealthPubSub

  require Logger

  @type entity_type :: :gateway | :agent | :checker | :collector | :core | :web | :custom
  @type state :: atom()

  defp repo_enabled? do
    Application.get_env(:serviceradar_core, :repo_enabled, true) != false
  end

  defp ensure_tracking_ready do
    if repo_enabled?() do
      :ok
    else
      {:error, :repo_disabled}
    end
  end

  # =============================================================================
  # State Change Recording
  # =============================================================================

  @doc """
  Records a state change for any entity type.

  Called by:
  - PublishStateChange (state machine transitions)
  - gRPC handlers (external service health)
  - Service heartbeats

  ## Options

  - `:old_state` - Previous state (optional, nil for first event)
  - `:new_state` - Current state (required)
  - `:reason` - Reason for change (optional)
  - `:node` - Cluster node recording this (defaults to current node)
  - `:metadata` - Additional context
  - `:broadcast` - Whether to broadcast via PubSub (default: true)
  """
  @spec record_state_change(entity_type(), String.t(), keyword()) ::
          {:ok, struct()} | {:error, term()}
  def record_state_change(entity_type, entity_id, opts \\ []) do
    case ensure_tracking_ready() do
      :ok ->
        new_state = Keyword.fetch!(opts, :new_state)
        old_state = Keyword.get(opts, :old_state)
        reason = Keyword.get(opts, :reason)
        node = Keyword.get(opts, :node, to_string(node()))
        metadata = Keyword.get(opts, :metadata, %{})
        broadcast = Keyword.get(opts, :broadcast, true)

        # Simple actor - DB connection's search_path determines the schema
        actor = SystemActor.system(:health_tracker)

        attrs = %{
          entity_type: entity_type,
          entity_id: entity_id,
          old_state: old_state,
          new_state: new_state,
          reason: reason,
          node: node,
          metadata: metadata
        }

        result =
          HealthEvent
          |> Ash.Changeset.for_create(:record, attrs, actor: actor)
          |> Ash.create()

        case result do
          {:ok, event} ->
            Logger.debug("Recorded health event: #{entity_type} #{entity_id} -> #{new_state}")
            maybe_publish_health_log(event)
            maybe_broadcast_health_event(event, broadcast)

            {:ok, event}

          {:error, error} ->
            Logger.warning("Failed to record health event: #{inspect(error)}")
            {:error, error}
        end

      {:error, reason} ->
        return_with_skip(entity_type, entity_id, reason)
    end
  end

  defp maybe_publish_health_log(event) do
    case HealthWriter.write(event) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to publish health log: #{inspect(reason)}")
    end
  end

  defp maybe_broadcast_health_event(event, true), do: HealthPubSub.broadcast_health_event(event)
  defp maybe_broadcast_health_event(_event, false), do: :ok

  # =============================================================================
  # Health Check Recording (from gRPC)
  # =============================================================================

  @doc """
  Records a health check result from a gRPC health check.

  Called by gRPC handlers when an agent reports health check results
  for external services (datasvc, sync, zen, etc.).

  ## Options

  - `:healthy` - Whether the service is healthy (required)
  - `:latency_ms` - Response time in milliseconds
  - `:error` - Error message if unhealthy
  - `:metadata` - Additional context
  """
  @spec record_health_check(entity_type(), String.t(), keyword()) ::
          {:ok, struct()} | {:error, term()}
  def record_health_check(entity_type, entity_id, opts \\ []) do
    case ensure_tracking_ready() do
      :ok ->
        healthy = Keyword.fetch!(opts, :healthy)
        latency_ms = Keyword.get(opts, :latency_ms)
        error = Keyword.get(opts, :error)
        metadata = Keyword.get(opts, :metadata, %{})

        # Determine new state based on health
        new_state = if healthy, do: :healthy, else: :unhealthy

        # Get previous state to detect changes
        old_state =
          case current_status(entity_type, entity_id) do
            {:ok, %{new_state: prev}} -> prev
            _ -> nil
          end

        # Only record if state changed (or first event)
        if old_state == new_state do
          # State unchanged, just return ok
          {:ok, :unchanged}
        else
          record_state_change(entity_type, entity_id,
            old_state: old_state,
            new_state: new_state,
            reason: if(healthy, do: :health_check_passed, else: :health_check_failed),
            metadata:
              Map.merge(metadata, %{
                latency_ms: latency_ms,
                error: error
              })
          )
        end

      {:error, reason} ->
        return_with_skip(entity_type, entity_id, reason)
    end
  end

  # =============================================================================
  # Service Heartbeats
  # =============================================================================

  @doc """
  Records a heartbeat from an Elixir service (core, web-ng, gateway).

  Elixir services call this periodically to report their health.
  If a service stops sending heartbeats, StateMonitor will detect
  the timeout and record an offline event.

  ## Options

  - `:healthy` - Whether the service is healthy (default: true)
  - `:metadata` - Additional context (version, uptime, etc.)
  """
  @spec heartbeat(entity_type(), String.t(), keyword()) ::
          {:ok, struct()} | {:ok, :unchanged} | {:error, term()}
  def heartbeat(entity_type, entity_id, opts \\ []) do
    case ensure_tracking_ready() do
      :ok ->
        healthy = Keyword.get(opts, :healthy, true)
        metadata = Keyword.get(opts, :metadata, %{})

        new_state = if healthy, do: :healthy, else: :degraded

        # Get previous state
        old_state =
          case current_status(entity_type, entity_id) do
            {:ok, %{new_state: prev}} -> prev
            _ -> nil
          end

        # Record event if state changed or first heartbeat
        if old_state != new_state or old_state == nil do
          record_state_change(entity_type, entity_id,
            old_state: old_state,
            new_state: new_state,
            reason: :heartbeat,
            metadata: metadata
          )
        else
          {:ok, :unchanged}
        end

      {:error, reason} ->
        return_with_skip(entity_type, entity_id, reason)
    end
  end

  # =============================================================================
  # Query Functions
  # =============================================================================

  @doc """
  Gets the current (most recent) health status for an entity.
  """
  @spec current_status(entity_type(), String.t()) ::
          {:ok, struct()} | {:ok, nil} | {:error, term()}
  def current_status(entity_type, entity_id) do
    require Ash.Query

    case ensure_tracking_ready() do
      :ok ->
        # Simple actor - DB connection's search_path determines the schema
        actor = SystemActor.system(:health_tracker)

        HealthEvent
        |> Ash.Query.filter(
          entity_type == ^entity_type and
            entity_id == ^entity_id
        )
        |> Ash.Query.sort(recorded_at: :desc)
        |> Ash.Query.limit(1)
        |> Ash.read_one(actor: actor)

      {:error, reason} ->
        return_with_skip(entity_type, entity_id, reason)
    end
  end

  @doc """
  Gets the health timeline for an entity.

  ## Options

  - `:hours` - Number of hours of history (default: 24)
  - `:limit` - Maximum events to return (default: 100)
  """
  @spec timeline(entity_type(), String.t(), keyword()) ::
          {:ok, [struct()]} | {:error, term()}
  def timeline(entity_type, entity_id, opts \\ []) do
    hours = Keyword.get(opts, :hours, 24)
    limit = Keyword.get(opts, :limit, 100)

    since = DateTime.add(DateTime.utc_now(), -hours, :hour)

    case ensure_tracking_ready() do
      :ok ->
        require Ash.Query

        # Simple actor - DB connection's search_path determines the schema
        actor = SystemActor.system(:health_tracker)

        HealthEvent
        |> Ash.Query.filter(
          entity_type == ^entity_type and
            entity_id == ^entity_id and
            recorded_at >= ^since
        )
        |> Ash.Query.sort(recorded_at: :desc)
        |> Ash.Query.limit(limit)
        |> Ash.read(actor: actor)

      {:error, reason} ->
        return_with_skip(entity_type, entity_id, reason)
    end
  end

  @doc """
  Gets a health summary.

  Returns counts by entity type and current state.
  """
  @spec summary() :: {:ok, map()} | {:error, term()}
  def summary do
    require Ash.Query

    case ensure_tracking_ready() do
      :ok ->
        # Simple actor - DB connection's search_path determines the schema
        actor = SystemActor.system(:health_tracker)

        # Get the most recent event for each entity
        # This is a simplified approach - for production, use a materialized view
        case HealthEvent
             |> Ash.Query.sort(recorded_at: :desc)
             |> Ash.read(actor: actor) do
          {:ok, events} ->
            {:ok, build_summary(events)}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        return_with_skip(:summary, "all", reason)
    end
  end

  defp build_summary(events) do
    events
    |> Enum.uniq_by(fn e -> {e.entity_type, e.entity_id} end)
    |> Enum.group_by(& &1.entity_type)
    |> Map.new(fn {entity_type, type_events} ->
      by_state =
        type_events
        |> Enum.group_by(& &1.new_state)
        |> Map.new(fn {state, state_events} -> {state, length(state_events)} end)

      {entity_type, %{total: length(type_events), by_state: by_state}}
    end)
  end

  @doc """
  Gets recent health events across all entities.

  ## Options

  - `:limit` - Maximum events to return (default: 50)
  - `:entity_type` - Filter by entity type (optional)
  """
  @spec recent_events(keyword()) :: {:ok, [struct()]} | {:error, term()}
  def recent_events(opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    entity_type = Keyword.get(opts, :entity_type)

    case ensure_tracking_ready() do
      :ok ->
        require Ash.Query

        # Simple actor - DB connection's search_path determines the schema
        actor = SystemActor.system(:health_tracker)

        query =
          HealthEvent
          |> Ash.Query.sort(recorded_at: :desc)
          |> Ash.Query.limit(limit)

        query =
          if entity_type do
            Ash.Query.filter(query, entity_type == ^entity_type)
          else
            query
          end

        Ash.read(query, actor: actor)

      {:error, reason} ->
        return_with_skip(:recent, "all", reason)
    end
  end

  defp return_with_skip(entity_type, entity_id, reason) do
    Logger.debug("Skipping health tracking for #{entity_type} #{entity_id}: #{inspect(reason)}")

    {:error, reason}
  end
end
