defmodule ServiceRadarWebNG.CameraRelayHealth do
  @moduledoc """
  Web-facing relay health context derived from the standard event and alert
  models.
  """

  alias ServiceRadar.Camera.RelayHealthEventRouter
  alias ServiceRadar.Monitoring.Alert
  alias ServiceRadar.Monitoring.OcsfEvent

  require Ash.Query

  @default_event_limit 6
  @default_alert_limit 6
  @default_scan_multiplier 5

  def overview(opts \\ []) do
    scope = Keyword.fetch!(opts, :scope)
    event_limit = parse_limit(Keyword.get(opts, :event_limit), @default_event_limit)
    alert_limit = parse_limit(Keyword.get(opts, :alert_limit), @default_alert_limit)

    with {:ok, recent_events} <- list_recent_events(scope, event_limit * @default_scan_multiplier),
         {:ok, active_alerts} <- list_active_alerts(scope, alert_limit * @default_scan_multiplier) do
      {:ok,
       %{
         recent_events:
           recent_events
           |> Enum.filter(&relay_health_event?/1)
           |> Enum.take(event_limit)
           |> Enum.map(&normalize_event/1),
         active_alerts:
           active_alerts
           |> Enum.filter(&relay_health_alert?/1)
           |> Enum.take(alert_limit)
           |> Enum.map(&normalize_alert/1)
       }}
    end
  end

  defp list_recent_events(scope, limit) do
    query =
      OcsfEvent
      |> Ash.Query.for_read(:read, %{}, scope: scope)
      |> Ash.Query.sort(time: :desc)
      |> Ash.Query.limit(limit)

    Ash.read(query, scope: scope, domain: ServiceRadar.Monitoring)
  end

  defp list_active_alerts(scope, limit) do
    query =
      Alert
      |> Ash.Query.for_read(:active, %{}, scope: scope)
      |> Ash.Query.sort(triggered_at: :desc)
      |> Ash.Query.limit(limit)

    Ash.read(query, scope: scope, domain: ServiceRadar.Monitoring)
  end

  defp relay_health_event?(event) do
    log_name = map_value(event, :log_name)
    log_name in RelayHealthEventRouter.relay_health_log_names()
  end

  defp relay_health_alert?(alert) do
    log_name =
      alert
      |> map_value(:metadata, %{})
      |> map_value("log_name")

    log_name in RelayHealthEventRouter.relay_health_alert_log_names()
  end

  defp normalize_event(event) do
    metadata = map_value(event, :metadata, %{})

    %{
      id: map_value(event, :id),
      time: map_value(event, :time),
      message: map_value(event, :message),
      log_name: map_value(event, :log_name),
      severity: map_value(event, :severity),
      status: map_value(event, :status),
      status_detail: map_value(event, :status_detail),
      relay_health_kind: map_value(metadata, "relay_health_kind"),
      relay_session_id: map_value(metadata, "relay_session_id"),
      gateway_id: map_value(metadata, "gateway_id"),
      camera_source_id: map_value(metadata, "camera_source_id"),
      reason:
        map_value(metadata, "failure_reason") ||
          map_value(metadata, "reason") ||
          map_value(metadata, "close_reason")
    }
  end

  defp normalize_alert(alert) do
    metadata = map_value(alert, :metadata, %{})

    %{
      id: map_value(alert, :id),
      title: map_value(alert, :title),
      description: map_value(alert, :description),
      status: normalize_atom(map_value(alert, :status)),
      severity: normalize_atom(map_value(alert, :severity)),
      triggered_at: map_value(alert, :triggered_at),
      notification_count: map_value(alert, :notification_count, 0),
      last_notification_at: map_value(alert, :last_notification_at),
      log_name: map_value(metadata, "log_name"),
      log_provider: map_value(metadata, "log_provider")
    }
  end

  defp normalize_atom(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_atom(value), do: value

  defp parse_limit(value, _default) when is_integer(value) and value > 0, do: value
  defp parse_limit(_value, default), do: default

  defp map_value(map, key, default \\ nil)

  defp map_value(map, key, default) when is_map(map) do
    Map.get(map, key, Map.get(map, to_string(key), default))
  end

  defp map_value(_map, _key, default), do: default
end
