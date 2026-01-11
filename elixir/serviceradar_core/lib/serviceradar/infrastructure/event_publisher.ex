defmodule ServiceRadar.Infrastructure.EventPublisher do
  @moduledoc """
  Publishes infrastructure state logs to NATS JetStream for promotion.

  Logs are published to tenant-scoped subjects following the pattern:
  `logs.internal.infrastructure.{event_type}`

  ## Event Types

  - `state_change` - Entity changed state (e.g., online -> offline)
  - `registered` - New entity registered
  - `deregistered` - Entity removed
  - `health_change` - Health status changed
  - `heartbeat_timeout` - Entity missed heartbeat deadline

  ## Log Payload Schema

  ```json
  {
    "class_uid": 1008,
    "activity_id": 3,
    "message": "Gateway gateway-123 changed from healthy to degraded",
    "tenant_id": "uuid",
    "log_name": "infra.state_change",
    "log_provider": "serviceradar.core",
    "timestamp": "2024-01-01T00:00:00Z"
  }
  ```

  ## Usage

      # Publish a state change log
      EventPublisher.publish_state_change(
        entity_type: :gateway,
        entity_id: "gateway-123",
        tenant_id: tenant.id,
        tenant_slug: tenant.slug,
        old_state: :healthy,
        new_state: :degraded,
        reason: :heartbeat_timeout
      )

      # Or use the shorthand for after_transition hooks
      EventPublisher.on_state_transition(gateway, :healthy, :degraded, %{})
  """

  alias ServiceRadar.EventWriter.OCSF
  alias ServiceRadar.Events.InternalLogPublisher

  require Logger

  @entity_types [:gateway, :agent, :checker, :collector]
  @event_types [:state_change, :registered, :deregistered, :health_change, :heartbeat_timeout]

  @type entity_type :: :gateway | :agent | :checker | :collector
  @type event_type :: :state_change | :registered | :deregistered | :health_change | :heartbeat_timeout

  @doc """
  Publishes a state change log to NATS JetStream.

  ## Options

  - `:entity_type` - The type of entity (required)
  - `:entity_id` - The entity's unique identifier (required)
  - `:tenant_id` - The tenant UUID (required)
  - `:tenant_slug` - The tenant slug for subject routing (required)
  - `:old_state` - Previous state (required)
  - `:new_state` - New state (required)
  - `:reason` - Why the state changed (optional)
  - `:partition_id` - Partition UUID (optional)
  - `:metadata` - Additional log metadata (optional)
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

    payload =
      build_log_payload(
        :state_change,
        entity_type,
        entity_id,
        tenant_id,
        partition_id,
        %{
          old_state: to_string(old_state),
          new_state: to_string(new_state),
          reason: reason && to_string(reason)
        },
        metadata
      )

    publish_log(:state_change, payload, tenant_id, tenant_slug)
  end

  @doc """
  Hook for AshStateMachine after_transition callbacks.

  Called automatically when an entity's state changes. Extracts necessary
  fields from the record and publishes the log.

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
      Logger.warning("Cannot publish state change log: missing tenant info",
        entity_type: entity_type,
        entity_id: entity_id
      )

      {:error, :missing_tenant}
    end
  end

  @doc """
  Publishes a registration log when a new entity is registered.
  """
  @spec publish_registered(entity_type(), String.t(), String.t(), String.t(), keyword()) ::
          :ok | {:error, term()}
  def publish_registered(entity_type, entity_id, tenant_id, tenant_slug, opts \\ []) do
    partition_id = Keyword.get(opts, :partition_id)
    metadata = Keyword.get(opts, :metadata, %{})
    initial_state = Keyword.get(opts, :initial_state)

    payload =
      build_log_payload(
        :registered,
        entity_type,
        entity_id,
        tenant_id,
        partition_id,
        %{initial_state: initial_state && to_string(initial_state)},
        metadata
      )

    publish_log(:registered, payload, tenant_id, tenant_slug)
  end

  @doc """
  Publishes a deregistration log when an entity is removed.
  """
  @spec publish_deregistered(entity_type(), String.t(), String.t(), String.t(), keyword()) ::
          :ok | {:error, term()}
  def publish_deregistered(entity_type, entity_id, tenant_id, tenant_slug, opts \\ []) do
    partition_id = Keyword.get(opts, :partition_id)
    metadata = Keyword.get(opts, :metadata, %{})
    final_state = Keyword.get(opts, :final_state)
    reason = Keyword.get(opts, :reason)

    payload =
      build_log_payload(
        :deregistered,
        entity_type,
        entity_id,
        tenant_id,
        partition_id,
        %{final_state: final_state && to_string(final_state), reason: reason},
        metadata
      )

    publish_log(:deregistered, payload, tenant_id, tenant_slug)
  end

  @doc """
  Publishes a heartbeat timeout log.
  """
  @spec publish_heartbeat_timeout(entity_type(), String.t(), String.t(), String.t(), keyword()) ::
          :ok | {:error, term()}
  def publish_heartbeat_timeout(entity_type, entity_id, tenant_id, tenant_slug, opts \\ []) do
    partition_id = Keyword.get(opts, :partition_id)
    metadata = Keyword.get(opts, :metadata, %{})
    last_seen = Keyword.get(opts, :last_seen)
    current_state = Keyword.get(opts, :current_state)

    payload =
      build_log_payload(
        :heartbeat_timeout,
        entity_type,
        entity_id,
        tenant_id,
        partition_id,
        %{
          last_seen: last_seen && DateTime.to_iso8601(last_seen),
          current_state: current_state && to_string(current_state)
        },
        metadata
      )

    publish_log(:heartbeat_timeout, payload, tenant_id, tenant_slug)
  end

  @doc """
  Publishes a health change log (without full state transition).
  """
  @spec publish_health_change(entity_type(), String.t(), String.t(), String.t(), boolean(), keyword()) ::
          :ok | {:error, term()}
  def publish_health_change(entity_type, entity_id, tenant_id, tenant_slug, is_healthy, opts \\ []) do
    partition_id = Keyword.get(opts, :partition_id)
    metadata = Keyword.get(opts, :metadata, %{})
    reason = Keyword.get(opts, :reason)

    payload =
      build_log_payload(
        :health_change,
        entity_type,
        entity_id,
        tenant_id,
        partition_id,
        %{is_healthy: is_healthy, reason: reason},
        metadata
      )

    publish_log(:health_change, payload, tenant_id, tenant_slug)
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

  defp build_log_payload(event_type, entity_type, entity_id, tenant_id, partition_id, data, metadata) do
    activity_id = activity_for_event(event_type)
    severity_id = severity_for_event(event_type, data)
    status_id = status_for_event(event_type, data)
    message = message_for_event(event_type, entity_type, entity_id, data)

    %{
      time: DateTime.utc_now(),
      class_uid: OCSF.class_event_log_activity(),
      category_uid: OCSF.category_system_activity(),
      type_uid: OCSF.type_uid(OCSF.class_event_log_activity(), activity_id),
      activity_id: activity_id,
      activity_name: OCSF.log_activity_name(activity_id),
      severity_id: severity_id,
      severity: OCSF.severity_name(severity_id),
      message: message,
      status_id: status_id,
      status: OCSF.status_name(status_id),
      metadata:
        OCSF.build_metadata(
          version: "1.7.0",
          product_name: "ServiceRadar Core",
          correlation_uid: "#{entity_type}:#{entity_id}"
        ),
      observables: build_observables(entity_id),
      actor: OCSF.build_actor(app_name: "serviceradar.core", process: "infrastructure"),
      log_name: "infra.#{event_type}",
      log_provider: "serviceradar.core",
      log_level: log_level_for_severity(severity_id),
      unmapped:
        %{
          "event_type" => to_string(event_type),
          "entity_type" => to_string(entity_type),
          "entity_id" => entity_id,
          "partition_id" => partition_id
        }
        |> Map.merge(stringify_keys(data))
        |> Map.merge(stringify_keys(metadata || %{})),
      tenant_id: tenant_id
    }
  end

  defp publish_log(event_type, payload, tenant_id, tenant_slug) do
    subject = "infrastructure.#{event_type}"

    case InternalLogPublisher.publish(subject, payload, tenant_id: tenant_id, tenant_slug: tenant_slug) do
      :ok ->
        :telemetry.execute(
          [:serviceradar, :infrastructure, :log_published],
          %{count: 1},
          %{event_type: to_string(event_type), subject: "logs.internal.#{subject}"}
        )

        :ok

      {:error, reason} = error ->
        Logger.warning("Failed to publish infrastructure log",
          reason: inspect(reason),
          event_type: event_type
        )

        :telemetry.execute(
          [:serviceradar, :infrastructure, :log_publish_failed],
          %{count: 1},
          %{reason: reason, subject: "logs.internal.#{subject}"}
        )

        error
    end
  end

  defp activity_for_event(:registered), do: OCSF.activity_log_create()
  defp activity_for_event(:deregistered), do: OCSF.activity_log_delete()
  defp activity_for_event(_), do: OCSF.activity_log_update()

  defp severity_for_event(:heartbeat_timeout, _data), do: OCSF.severity_high()
  defp severity_for_event(:health_change, data) do
    case data[:is_healthy] || data["is_healthy"] do
      true -> OCSF.severity_informational()
      false -> OCSF.severity_high()
      _ -> severity_for_state(data[:new_state] || data["new_state"])
    end
  end
  defp severity_for_event(:state_change, data), do: severity_for_state(data[:new_state] || data["new_state"])
  defp severity_for_event(_event_type, _data), do: OCSF.severity_informational()

  defp status_for_event(:heartbeat_timeout, _data), do: OCSF.status_failure()

  defp status_for_event(:health_change, data) do
    case data[:is_healthy] || data["is_healthy"] do
      false -> OCSF.status_failure()
      _ -> OCSF.status_success()
    end
  end

  defp status_for_event(_event_type, _data), do: OCSF.status_success()

  defp message_for_event(event_type, entity_type, entity_id, data) do
    entity_label = "#{entity_type} #{entity_id}"

    case event_type do
      :state_change ->
        old_state = data[:old_state] || data["old_state"] || "unknown"
        new_state = data[:new_state] || data["new_state"] || "unknown"
        "#{entity_label} changed from #{old_state} to #{new_state}"

      :health_change ->
        health = data[:is_healthy] || data["is_healthy"]
        state = if health, do: "healthy", else: "unhealthy"
        "#{entity_label} health changed to #{state}"

      :heartbeat_timeout ->
        "#{entity_label} missed heartbeat deadline"

      :registered ->
        "#{entity_label} registered"

      :deregistered ->
        "#{entity_label} deregistered"

      _ ->
        "#{entity_label} event #{event_type}"
    end
  end

  defp build_observables(nil), do: []
  defp build_observables(value), do: [OCSF.build_observable(value, "Resource UID", 99)]

  defp log_level_for_severity(severity_id) do
    case severity_id do
      6 -> "fatal"
      5 -> "critical"
      4 -> "error"
      3 -> "warning"
      2 -> "notice"
      1 -> "info"
      _ -> "unknown"
    end
  end

  defp severity_for_state(state) when state in [:offline, :disconnected, :failing, :unhealthy],
    do: OCSF.severity_high()

  defp severity_for_state(state) when state in [:degraded, :recovering],
    do: OCSF.severity_medium()

  defp severity_for_state(state) when state in [:healthy, :connected, :active],
    do: OCSF.severity_informational()

  defp severity_for_state(_), do: OCSF.severity_low()

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  defp stringify_keys(_), do: %{}

  defp entity_type_from_record(%ServiceRadar.Infrastructure.Gateway{}), do: :gateway
  defp entity_type_from_record(%ServiceRadar.Infrastructure.Agent{}), do: :agent
  defp entity_type_from_record(%ServiceRadar.Infrastructure.Checker{}), do: :checker
  defp entity_type_from_record(%{__struct__: module}), do: module |> Module.split() |> List.last() |> String.downcase() |> String.to_atom()
  defp entity_type_from_record(_), do: :unknown

  defp entity_id_from_record(%ServiceRadar.Infrastructure.Gateway{id: id}), do: id
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
