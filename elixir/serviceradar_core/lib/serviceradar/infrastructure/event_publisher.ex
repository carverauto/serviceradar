defmodule ServiceRadar.Infrastructure.EventPublisher do
  @moduledoc """
  Publishes infrastructure state events to NATS JetStream.

  Events are published to tenant-scoped subjects following the pattern:
  `sr.infra.{tenant_slug}.{entity_type}.{event_type}`

  ## Event Types

  - `state_change` - Entity changed state (e.g., online -> offline)
  - `registered` - New entity registered
  - `deregistered` - Entity removed
  - `health_change` - Health status changed
  - `heartbeat_timeout` - Entity missed heartbeat deadline

  ## Event Schema

  ```json
  {
    "event_type": "state_change",
    "entity_type": "poller",
    "entity_id": "poller-123",
    "tenant_id": "uuid",
    "tenant_slug": "acme",
    "partition_id": "uuid",
    "old_state": "healthy",
    "new_state": "degraded",
    "reason": "heartbeat_timeout",
    "metadata": {},
    "timestamp": "2024-01-01T00:00:00Z"
  }
  ```

  ## Usage

      # Publish a state change event
      EventPublisher.publish_state_change(
        entity_type: :poller,
        entity_id: "poller-123",
        tenant_id: tenant.id,
        tenant_slug: tenant.slug,
        old_state: :healthy,
        new_state: :degraded,
        reason: :heartbeat_timeout
      )

      # Or use the shorthand for after_transition hooks
      EventPublisher.on_state_transition(poller, :healthy, :degraded, %{})
  """

  alias ServiceRadar.NATS.Connection

  require Logger

  @entity_types [:poller, :agent, :checker, :collector]
  @event_types [:state_change, :registered, :deregistered, :health_change, :heartbeat_timeout]

  @type entity_type :: :poller | :agent | :checker | :collector
  @type event_type :: :state_change | :registered | :deregistered | :health_change | :heartbeat_timeout

  @doc """
  Publishes a state change event to NATS JetStream.

  ## Options

  - `:entity_type` - The type of entity (required)
  - `:entity_id` - The entity's unique identifier (required)
  - `:tenant_id` - The tenant UUID (required)
  - `:tenant_slug` - The tenant slug for subject routing (required)
  - `:old_state` - Previous state (required)
  - `:new_state` - New state (required)
  - `:reason` - Why the state changed (optional)
  - `:partition_id` - Partition UUID (optional)
  - `:metadata` - Additional event metadata (optional)
  """
  @spec publish_state_change(keyword()) :: :ok | {:error, term()}
  def publish_state_change(opts) do
    entity_type = Keyword.fetch!(opts, :entity_type)
    entity_id = Keyword.fetch!(opts, :entity_id)
    tenant_id = Keyword.fetch!(opts, :tenant_id)
    tenant_slug = Keyword.fetch!(opts, :tenant_slug)
    old_state = Keyword.fetch!(opts, :old_state)
    new_state = Keyword.fetch!(opts, :new_state)
    reason = Keyword.get(opts, :reason)
    partition_id = Keyword.get(opts, :partition_id)
    metadata = Keyword.get(opts, :metadata, %{})

    event = build_event(
      :state_change,
      entity_type,
      entity_id,
      tenant_id,
      tenant_slug,
      partition_id,
      %{
        old_state: to_string(old_state),
        new_state: to_string(new_state),
        reason: reason && to_string(reason)
      },
      metadata
    )

    subject = build_subject(tenant_slug, entity_type, :state_change)
    publish(subject, event)
  end

  @doc """
  Hook for AshStateMachine after_transition callbacks.

  Called automatically when an entity's state changes. Extracts necessary
  fields from the record and publishes the event.

  ## Example in Ash Resource

      state_machine do
        transitions do
          transition :go_offline, from: :healthy, to: :offline do
            change after_transition: &EventPublisher.on_state_transition/4
          end
        end
      end
  """
  @spec on_state_transition(struct(), atom(), atom(), map()) :: :ok | {:error, term()}
  def on_state_transition(record, old_state, new_state, context \\ %{}) do
    entity_type = entity_type_from_record(record)
    entity_id = entity_id_from_record(record)
    tenant_id = Map.get(record, :tenant_id)

    # Try to get tenant_slug from context or lookup
    tenant_slug = context[:tenant_slug] || lookup_tenant_slug(tenant_id)
    partition_id = Map.get(record, :partition_id)

    if tenant_id && tenant_slug do
      publish_state_change(
        entity_type: entity_type,
        entity_id: entity_id,
        tenant_id: tenant_id,
        tenant_slug: tenant_slug,
        partition_id: partition_id,
        old_state: old_state,
        new_state: new_state,
        reason: context[:reason],
        metadata: context[:metadata] || %{}
      )
    else
      Logger.warning(
        "Cannot publish state change event: missing tenant info for #{entity_type} #{entity_id}"
      )

      {:error, :missing_tenant}
    end
  end

  @doc """
  Publishes a registration event when a new entity is registered.
  """
  @spec publish_registered(entity_type(), String.t(), String.t(), String.t(), keyword()) ::
          :ok | {:error, term()}
  def publish_registered(entity_type, entity_id, tenant_id, tenant_slug, opts \\ []) do
    partition_id = Keyword.get(opts, :partition_id)
    metadata = Keyword.get(opts, :metadata, %{})
    initial_state = Keyword.get(opts, :initial_state)

    event = build_event(
      :registered,
      entity_type,
      entity_id,
      tenant_id,
      tenant_slug,
      partition_id,
      %{initial_state: initial_state && to_string(initial_state)},
      metadata
    )

    subject = build_subject(tenant_slug, entity_type, :registered)
    publish(subject, event)
  end

  @doc """
  Publishes a deregistration event when an entity is removed.
  """
  @spec publish_deregistered(entity_type(), String.t(), String.t(), String.t(), keyword()) ::
          :ok | {:error, term()}
  def publish_deregistered(entity_type, entity_id, tenant_id, tenant_slug, opts \\ []) do
    partition_id = Keyword.get(opts, :partition_id)
    metadata = Keyword.get(opts, :metadata, %{})
    final_state = Keyword.get(opts, :final_state)
    reason = Keyword.get(opts, :reason)

    event = build_event(
      :deregistered,
      entity_type,
      entity_id,
      tenant_id,
      tenant_slug,
      partition_id,
      %{final_state: final_state && to_string(final_state), reason: reason},
      metadata
    )

    subject = build_subject(tenant_slug, entity_type, :deregistered)
    publish(subject, event)
  end

  @doc """
  Publishes a heartbeat timeout event.
  """
  @spec publish_heartbeat_timeout(entity_type(), String.t(), String.t(), String.t(), keyword()) ::
          :ok | {:error, term()}
  def publish_heartbeat_timeout(entity_type, entity_id, tenant_id, tenant_slug, opts \\ []) do
    partition_id = Keyword.get(opts, :partition_id)
    metadata = Keyword.get(opts, :metadata, %{})
    last_seen = Keyword.get(opts, :last_seen)
    current_state = Keyword.get(opts, :current_state)

    event = build_event(
      :heartbeat_timeout,
      entity_type,
      entity_id,
      tenant_id,
      tenant_slug,
      partition_id,
      %{
        last_seen: last_seen && DateTime.to_iso8601(last_seen),
        current_state: current_state && to_string(current_state)
      },
      metadata
    )

    subject = build_subject(tenant_slug, entity_type, :heartbeat_timeout)
    publish(subject, event)
  end

  @doc """
  Publishes a health change event (without full state transition).
  """
  @spec publish_health_change(entity_type(), String.t(), String.t(), String.t(), boolean(), keyword()) ::
          :ok | {:error, term()}
  def publish_health_change(entity_type, entity_id, tenant_id, tenant_slug, is_healthy, opts \\ []) do
    partition_id = Keyword.get(opts, :partition_id)
    metadata = Keyword.get(opts, :metadata, %{})
    reason = Keyword.get(opts, :reason)

    event = build_event(
      :health_change,
      entity_type,
      entity_id,
      tenant_id,
      tenant_slug,
      partition_id,
      %{is_healthy: is_healthy, reason: reason},
      metadata
    )

    subject = build_subject(tenant_slug, entity_type, :health_change)
    publish(subject, event)
  end

  @doc """
  Returns valid entity types for validation.
  """
  @spec entity_types() :: [entity_type()]
  def entity_types, do: @entity_types

  @doc """
  Returns valid event types for validation.
  """
  @spec event_types() :: [event_type()]
  def event_types, do: @event_types

  # Private functions

  defp build_event(event_type, entity_type, entity_id, tenant_id, tenant_slug, partition_id, data, metadata) do
    %{
      event_type: to_string(event_type),
      entity_type: to_string(entity_type),
      entity_id: entity_id,
      tenant_id: tenant_id,
      tenant_slug: tenant_slug,
      partition_id: partition_id,
      data: data,
      metadata: metadata,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      version: "1.0"
    }
  end

  defp build_subject(tenant_slug, entity_type, event_type) do
    "sr.infra.#{tenant_slug}.#{entity_type}.#{event_type}"
  end

  defp publish(subject, event) do
    payload = Jason.encode!(event)

    case Connection.publish(subject, payload) do
      :ok ->
        :telemetry.execute(
          [:serviceradar, :infrastructure, :event_published],
          %{count: 1},
          %{
            event_type: event.event_type,
            entity_type: event.entity_type,
            subject: subject
          }
        )

        :ok

      {:error, reason} = error ->
        Logger.warning("Failed to publish event to #{subject}: #{inspect(reason)}")

        :telemetry.execute(
          [:serviceradar, :infrastructure, :event_publish_failed],
          %{count: 1},
          %{reason: reason, subject: subject}
        )

        error
    end
  end

  defp entity_type_from_record(%ServiceRadar.Infrastructure.Poller{}), do: :poller
  defp entity_type_from_record(%ServiceRadar.Infrastructure.Agent{}), do: :agent
  defp entity_type_from_record(%ServiceRadar.Infrastructure.Checker{}), do: :checker
  defp entity_type_from_record(%{__struct__: module}), do: module |> Module.split() |> List.last() |> String.downcase() |> String.to_atom()
  defp entity_type_from_record(_), do: :unknown

  defp entity_id_from_record(%ServiceRadar.Infrastructure.Poller{id: id}), do: id
  defp entity_id_from_record(%ServiceRadar.Infrastructure.Agent{uid: uid}), do: uid
  defp entity_id_from_record(%ServiceRadar.Infrastructure.Checker{id: id}), do: to_string(id)
  defp entity_id_from_record(%{id: id}), do: to_string(id)
  defp entity_id_from_record(_), do: nil

  defp lookup_tenant_slug(nil), do: nil

  defp lookup_tenant_slug(tenant_id) do
    # Try to lookup tenant slug from cache or database
    # This is a fallback - prefer passing tenant_slug in context
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
