defmodule ServiceRadar.Infrastructure.HealthTracker do
  @moduledoc """
  Unified health tracking API for all infrastructure entities.

  All health status changes flow through this module to create HealthEvents,
  regardless of the source:

  - **State machine transitions** - Gateways, Agents, Checkers (via PublishStateChange)
  - **gRPC health checks** - External services checked by Go agents
  - **Service heartbeats** - Core, Web, and other Elixir services self-reporting
  - **Manual updates** - Admin/operator actions

  Health events are persisted to `health_events`, mirrored into `ocsf_events`,
  and broadcast via per-tenant PubSub topics for live UI updates.

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
                   │  OCSF Events  │
                   │  (database)   │
                   └───────────────┘

  ## Usage

      # Record a state change from any source
      HealthTracker.record_state_change(:agent, "agent-uid", tenant_id,
        old_state: :connected,
        new_state: :degraded,
        reason: :high_latency
      )

      # Record health check result from gRPC
      HealthTracker.record_health_check(:datasvc, "datasvc-node-1", tenant_id,
        healthy: false,
        latency_ms: 5000,
        error: "timeout"
      )

      # Record service heartbeat
      HealthTracker.heartbeat(:core, node_id, tenant_id,
        healthy: true,
        metadata: %{version: "1.0.0", uptime_seconds: 3600}
      )

      # Query health status
      HealthTracker.current_status(:gateway, "gateway-001", tenant_id)
      HealthTracker.timeline(:agent, "agent-uid", tenant_id, hours: 24)
      HealthTracker.summary(tenant_id)
  """

  alias ServiceRadar.Cluster.TenantSchemas
  alias ServiceRadar.Events.HealthWriter
  alias ServiceRadar.Infrastructure.{HealthEvent, HealthPubSub}

  require Logger

  @type entity_type :: :gateway | :agent | :checker | :collector | :core | :web | :custom
  @type state :: atom()

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
  @spec record_state_change(entity_type(), String.t(), String.t(), keyword()) ::
          {:ok, struct()} | {:error, term()}
  def record_state_change(entity_type, entity_id, tenant_id, opts \\ []) do
    new_state = Keyword.fetch!(opts, :new_state)
    old_state = Keyword.get(opts, :old_state)
    reason = Keyword.get(opts, :reason)
    node = Keyword.get(opts, :node, to_string(node()))
    metadata = Keyword.get(opts, :metadata, %{})
    broadcast = Keyword.get(opts, :broadcast, true)
    tenant_schema = TenantSchemas.schema_for_tenant(tenant_id)

    attrs = %{
      entity_type: entity_type,
      entity_id: entity_id,
      tenant_id: tenant_id,
      old_state: old_state,
      new_state: new_state,
      reason: reason,
      node: node,
      metadata: metadata
    }

    result =
      case tenant_schema do
        nil ->
          {:error, :tenant_schema_not_found}

        schema ->
          HealthEvent
          |> Ash.Changeset.for_create(:record, attrs, tenant: schema)
          |> Ash.create(authorize?: false)
      end

    case result do
      {:ok, event} ->
        Logger.debug("Recorded health event: #{entity_type} #{entity_id} -> #{new_state}")

        case HealthWriter.write(event) do
          :ok -> :ok
          {:error, reason} -> Logger.warning("Failed to write OCSF health event: #{inspect(reason)}")
        end

        if broadcast do
          HealthPubSub.broadcast_health_event(event)
        end

        {:ok, event}

      {:error, error} ->
        Logger.warning("Failed to record health event: #{inspect(error)}")
        {:error, error}
    end
  end

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
  @spec record_health_check(entity_type(), String.t(), String.t(), keyword()) ::
          {:ok, struct()} | {:error, term()}
  def record_health_check(entity_type, entity_id, tenant_id, opts \\ []) do
    healthy = Keyword.fetch!(opts, :healthy)
    latency_ms = Keyword.get(opts, :latency_ms)
    error = Keyword.get(opts, :error)
    metadata = Keyword.get(opts, :metadata, %{})

    # Determine new state based on health
    new_state = if healthy, do: :healthy, else: :unhealthy

    # Get previous state to detect changes
    old_state =
      case current_status(entity_type, entity_id, tenant_id) do
        {:ok, %{new_state: prev}} -> prev
        _ -> nil
      end

    # Only record if state changed (or first event)
    if old_state != new_state do
      record_state_change(entity_type, entity_id, tenant_id,
        old_state: old_state,
        new_state: new_state,
        reason: if(healthy, do: :health_check_passed, else: :health_check_failed),
        metadata: Map.merge(metadata, %{
          latency_ms: latency_ms,
          error: error
        })
      )
    else
      # State unchanged, just return ok
      {:ok, :unchanged}
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
  @spec heartbeat(entity_type(), String.t(), String.t(), keyword()) ::
          {:ok, struct()} | {:ok, :unchanged} | {:error, term()}
  def heartbeat(entity_type, entity_id, tenant_id, opts \\ []) do
    healthy = Keyword.get(opts, :healthy, true)
    metadata = Keyword.get(opts, :metadata, %{})

    new_state = if healthy, do: :healthy, else: :degraded

    # Get previous state
    old_state =
      case current_status(entity_type, entity_id, tenant_id) do
        {:ok, %{new_state: prev}} -> prev
        _ -> nil
      end

    # Record event if state changed or first heartbeat
    if old_state != new_state or old_state == nil do
      record_state_change(entity_type, entity_id, tenant_id,
        old_state: old_state,
        new_state: new_state,
        reason: :heartbeat,
        metadata: metadata
      )
    else
      {:ok, :unchanged}
    end
  end

  # =============================================================================
  # Query Functions
  # =============================================================================

  @doc """
  Gets the current (most recent) health status for an entity.
  """
  @spec current_status(entity_type(), String.t(), String.t()) ::
          {:ok, struct()} | {:ok, nil} | {:error, term()}
  def current_status(entity_type, entity_id, tenant_id) do
    require Ash.Query

    tenant_schema = TenantSchemas.schema_for_tenant(tenant_id)

    case tenant_schema do
      nil ->
        {:error, :tenant_schema_not_found}

      schema ->
        HealthEvent
        |> Ash.Query.filter(
          entity_type == ^entity_type and
            entity_id == ^entity_id and
            tenant_id == ^tenant_id
        )
        |> Ash.Query.sort(recorded_at: :desc)
        |> Ash.Query.limit(1)
        |> Ash.read_one(authorize?: false, tenant: schema)
    end
  end

  @doc """
  Gets the health timeline for an entity.

  ## Options

  - `:hours` - Number of hours of history (default: 24)
  - `:limit` - Maximum events to return (default: 100)
  """
  @spec timeline(entity_type(), String.t(), String.t(), keyword()) ::
          {:ok, [struct()]} | {:error, term()}
  def timeline(entity_type, entity_id, tenant_id, opts \\ []) do
    hours = Keyword.get(opts, :hours, 24)
    limit = Keyword.get(opts, :limit, 100)

    since = DateTime.add(DateTime.utc_now(), -hours, :hour)
    tenant_schema = TenantSchemas.schema_for_tenant(tenant_id)

    require Ash.Query

    case tenant_schema do
      nil ->
        {:error, :tenant_schema_not_found}

      schema ->
        HealthEvent
        |> Ash.Query.filter(
          entity_type == ^entity_type and
            entity_id == ^entity_id and
            tenant_id == ^tenant_id and
            recorded_at >= ^since
        )
        |> Ash.Query.sort(recorded_at: :desc)
        |> Ash.Query.limit(limit)
        |> Ash.read(authorize?: false, tenant: schema)
    end
  end

  @doc """
  Gets a health summary for a tenant.

  Returns counts by entity type and current state.
  """
  @spec summary(String.t()) :: {:ok, map()} | {:error, term()}
  def summary(tenant_id) do
    require Ash.Query
    tenant_schema = TenantSchemas.schema_for_tenant(tenant_id)

    # Get the most recent event for each entity
    # This is a simplified approach - for production, use a materialized view
    case tenant_schema do
      nil ->
        {:error, :tenant_schema_not_found}

      schema ->
        case HealthEvent
             |> Ash.Query.filter(tenant_id == ^tenant_id)
             |> Ash.Query.sort(recorded_at: :desc)
             |> Ash.read(authorize?: false, tenant: schema) do
          {:ok, events} ->
            # Dedupe by entity_type + entity_id (keep most recent)
            latest_by_entity =
              events
              |> Enum.uniq_by(fn e -> {e.entity_type, e.entity_id} end)

            # Group by entity_type, then by state
            summary =
              latest_by_entity
              |> Enum.group_by(& &1.entity_type)
              |> Enum.map(fn {entity_type, type_events} ->
                by_state =
                  type_events
                  |> Enum.group_by(& &1.new_state)
                  |> Enum.map(fn {state, state_events} -> {state, length(state_events)} end)
                  |> Map.new()

                {entity_type, %{total: length(type_events), by_state: by_state}}
              end)
              |> Map.new()

            {:ok, summary}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  @doc """
  Gets recent health events across all entities in a tenant.

  ## Options

  - `:limit` - Maximum events to return (default: 50)
  - `:entity_type` - Filter by entity type (optional)
  """
  @spec recent_events(String.t(), keyword()) :: {:ok, [struct()]} | {:error, term()}
  def recent_events(tenant_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    entity_type = Keyword.get(opts, :entity_type)
    tenant_schema = TenantSchemas.schema_for_tenant(tenant_id)

    require Ash.Query

    case tenant_schema do
      nil ->
        {:error, :tenant_schema_not_found}

      schema ->
        query =
          HealthEvent
          |> Ash.Query.filter(tenant_id == ^tenant_id)
          |> Ash.Query.sort(recorded_at: :desc)
          |> Ash.Query.limit(limit)

        query =
          if entity_type do
            Ash.Query.filter(query, entity_type == ^entity_type)
          else
            query
          end

        Ash.read(query, authorize?: false, tenant: schema)
    end
  end

end
