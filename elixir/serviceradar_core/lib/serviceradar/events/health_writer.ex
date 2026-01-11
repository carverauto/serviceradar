defmodule ServiceRadar.Events.HealthWriter do
  @moduledoc """
  Publishes internal health state logs to NATS for downstream promotion.
  """

  alias ServiceRadar.EventWriter.OCSF
  alias ServiceRadar.Events.InternalLogPublisher
  alias ServiceRadar.Infrastructure.HealthEvent

  require Logger

  @spec write(HealthEvent.t()) :: :ok | {:error, term()}
  def write(%HealthEvent{} = event) do
    if is_nil(event.tenant_id) do
      {:error, :missing_tenant_id}
    else
      payload = build_event_attrs(event)

      InternalLogPublisher.publish("health", payload, tenant_id: event.tenant_id)
    end
  rescue
    e ->
      Logger.warning("Failed to publish health log: #{inspect(e)}")
      {:error, e}
  end

  defp build_event_attrs(event) do
    severity_id = severity_for_state(event.new_state)
    activity_id = OCSF.activity_log_update()
    time = event.recorded_at || DateTime.utc_now()

    %{
      time: time,
      class_uid: OCSF.class_event_log_activity(),
      category_uid: OCSF.category_system_activity(),
      type_uid: OCSF.type_uid(OCSF.class_event_log_activity(), activity_id),
      activity_id: activity_id,
      activity_name: OCSF.log_activity_name(activity_id),
      severity_id: severity_id,
      severity: OCSF.severity_name(severity_id),
      message: message_for(event),
      status_id: OCSF.status_success(),
      status: OCSF.status_name(OCSF.status_success()),
      metadata:
        OCSF.build_metadata(
          version: "1.7.0",
          product_name: "ServiceRadar Core",
          correlation_uid: "#{event.entity_type}:#{event.entity_id}"
        ),
      observables: build_observables(event.entity_id),
      actor: OCSF.build_actor(app_name: "serviceradar.core", process: event.node),
      log_name: "health.state_change",
      log_provider: "serviceradar.core",
      log_level: log_level_for_severity(severity_id),
      unmapped: build_unmapped(event),
      tenant_id: event.tenant_id
    }
  end

  defp severity_for_state(state) when state in [:offline, :disconnected, :failing, :unhealthy],
    do: OCSF.severity_high()

  defp severity_for_state(state) when state in [:degraded, :recovering],
    do: OCSF.severity_medium()

  defp severity_for_state(state) when state in [:healthy, :connected, :active],
    do: OCSF.severity_informational()

  defp severity_for_state(_), do: OCSF.severity_low()

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

  defp message_for(event) do
    entity_type = event.entity_type |> to_string() |> humanize()
    entity_id = event.entity_id || "unknown"
    old_state = event.old_state |> state_label()
    new_state = event.new_state |> state_label()

    "#{entity_type} #{entity_id} changed from #{old_state} to #{new_state}"
  end

  defp state_label(nil), do: "unknown"
  defp state_label(state) when is_atom(state), do: Atom.to_string(state)
  defp state_label(state), do: to_string(state)

  defp build_unmapped(event) do
    %{
      "entity_type" => to_string(event.entity_type),
      "entity_id" => event.entity_id,
      "old_state" => state_label(event.old_state),
      "new_state" => state_label(event.new_state),
      "reason" => maybe_string(event.reason),
      "node" => event.node,
      "metadata" => stringify_keys(event.metadata || %{})
    }
  end

  defp maybe_string(nil), do: nil
  defp maybe_string(value) when is_atom(value), do: Atom.to_string(value)
  defp maybe_string(value), do: to_string(value)

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  defp stringify_keys(value), do: value

  defp build_observables(nil), do: []
  defp build_observables(""), do: []
  defp build_observables(value), do: [OCSF.build_observable(value, "Resource UID", 99)]

  defp humanize(value) when is_binary(value) do
    value
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp humanize(value), do: to_string(value)
end
