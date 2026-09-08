defmodule ServiceRadar.Observability.StatefulAlertEngine.EdgeAnomalyDisposition do
  @moduledoc """
  Seasonal-disposition handling for edge-spike anomaly events: deciding whether
  an `anomaly_open` event should be suppressed, escalated, or passed through
  based on the seasonal baseline for its series, tagging the event with the
  resulting operator context, and emitting disposition telemetry.

  The publicly exported entry points (`seasonal_disposition_*` and
  `tag_edge_anomaly_disposition/4`) are re-exported from
  `ServiceRadar.Observability.StatefulAlertEngine` for backward compatibility.
  """

  import ServiceRadar.Observability.StatefulAlertEngine.Helpers
  import ServiceRadar.Observability.StatefulAlertEngine.Record
  import ServiceRadar.Observability.StatefulAlertEngine.RuleMatcher
  import ServiceRadar.Observability.StatefulAlertEngine.Severity

  alias ServiceRadar.EventWriter.OCSF
  alias ServiceRadar.Observability.SeasonalDisposition.StateStore, as: SeasonalStateStore

  @doc false
  @spec seasonal_disposition_suppresses_edge_anomaly?(map(), map()) :: boolean()
  def seasonal_disposition_suppresses_edge_anomaly?(event, rule) do
    seasonal_disposition_action_for_edge_anomaly(event, rule) == :suppress
  end

  @doc false
  @spec seasonal_disposition_action_for_edge_anomaly(map(), map()) ::
          :suppress | :escalate | :pass_through
  def seasonal_disposition_action_for_edge_anomaly(event, rule) do
    case seasonal_disposition_for_edge_anomaly(event, rule) do
      {:ok, action, _attrs, _disposition} -> action
      :ignore -> :pass_through
    end
  end

  @doc false
  @spec seasonal_disposition_for_edge_anomaly(map(), map()) ::
          {:ok, :suppress | :escalate | :pass_through, map(), map() | nil} | :ignore
  def seasonal_disposition_for_edge_anomaly(event, rule) do
    with true <- anomaly_open_rule?(rule),
         {:ok, attrs} <- edge_spike_anomaly_attrs(event) do
      attrs
      |> lookup_seasonal_disposition()
      |> emit_and_return_seasonal_disposition()
    else
      {:error, reason} ->
        attrs = %{reason: reason}
        emit_anomaly_disposition_telemetry(:pass_through, attrs, nil)
        {:ok, :pass_through, attrs, nil}

      _ ->
        :ignore
    end
  end

  defp edge_spike_anomaly_attrs(event) do
    {attributes, resource_attributes} = event_match_sources(event)
    anomaly = get_nested_value(attributes, "anomaly") || %{}

    event_type =
      get_nested_value(attributes, "event_type") ||
        get_nested_value(resource_attributes, "event_type")

    state = get_nested_value(anomaly, "state") || get_nested_value(attributes, "anomaly.state")

    verdict_source =
      get_nested_value(attributes, "verdict_source") ||
        get_nested_value(anomaly, "verdict_source") ||
        get_nested_value(resource_attributes, "service_radar.verdict_source") ||
        get_nested_value(resource_attributes, "serviceradar.verdict_source")

    if match_value(event_type, ["anomaly", "anomaly_detection"]) and
         match_value(state, ["anomaly_open", "open", "anomalous"]) and
         verdict_source == "edge-spike" do
      series_key =
        get_nested_value(anomaly, "series_key") ||
          get_nested_value(attributes, "anomaly.series_key")

      metric_class =
        get_nested_value(anomaly, "metric_class") ||
          get_nested_value(attributes, "anomaly.metric_class")

      cond do
        not is_binary(series_key) or series_key == "" ->
          {:error, :missing_anomaly_series_key}

        not is_binary(metric_class) or metric_class == "" ->
          {:error, :missing_anomaly_metric_class}

        true ->
          {:ok,
           %{
             series_key: series_key,
             metric_class: metric_class,
             time: record_timestamp(event),
             device_uid: record_device_uid(event),
             verdict_source: verdict_source
           }}
      end
    else
      :ignore
    end
  end

  defp seasonal_source_for_metric_class(metric_class) when is_binary(metric_class) do
    case String.downcase(metric_class) do
      value when value in ["cpu", "sysmon.cpu"] ->
        {:ok, "cpu_seasonal"}

      value when value in ["memory", "mem", "sysmon.memory", "sysmon.mem"] ->
        {:ok, "memory_seasonal"}

      _ ->
        :ignore
    end
  end

  defp seasonal_source_for_metric_class(_metric_class), do: :ignore

  defp lookup_seasonal_disposition(attrs) do
    case seasonal_source_for_metric_class(attrs.metric_class) do
      {:ok, source} ->
        case SeasonalStateStore.lookup_window_disposition(source, attrs.series_key, attrs.time) do
          {:ok, disposition} ->
            {seasonal_disposition_action(disposition), attrs, disposition}

          {:error, reason} ->
            {:pass_through, Map.put(attrs, :reason, reason), nil}
        end

      :ignore ->
        {:pass_through, Map.put(attrs, :reason, :unsupported_seasonal_metric_class), nil}
    end
  end

  defp emit_and_return_seasonal_disposition({action, attrs, disposition}) do
    emit_anomaly_disposition_telemetry(action, attrs, disposition)
    {:ok, action, attrs, disposition}
  end

  @doc false
  @spec tag_edge_anomaly_disposition(
          map(),
          :suppress | :escalate | :pass_through,
          map(),
          map() | nil
        ) ::
          map()
  def tag_edge_anomaly_disposition(event, action, attrs, disposition) do
    payload = edge_anomaly_disposition_payload(action, attrs, disposition)

    event
    |> maybe_escalate_edge_anomaly_severity(action)
    |> put_service_radar_metadata("anomaly_disposition", payload)
    |> put_unmapped_value("anomaly_disposition", payload)
  end

  defp edge_anomaly_disposition_payload(action, attrs, disposition) do
    compact_map(%{
      "action" => Atom.to_string(action),
      "reason" => map_value(attrs, :reason),
      "series_key" => map_value(attrs, :series_key),
      "metric_class" => map_value(attrs, :metric_class),
      "seasonal_disposition" => map_value(disposition || %{}, :disposition),
      "seasonal_status" => map_value(disposition || %{}, :status),
      "seasonal_score" => map_value(disposition || %{}, :score),
      "seasonal_evaluated_at" => map_value(disposition || %{}, :evaluated_at),
      "seasonal_window_started_at" => map_value(disposition || %{}, :bucket_started_at),
      "seasonal_window_ended_at" => map_value(disposition || %{}, :bucket_ended_at)
    })
  end

  defp maybe_escalate_edge_anomaly_severity(event, :escalate) do
    severity_id =
      event
      |> fetch_attr(:severity_id)
      |> resolve_severity_id()
      |> max(OCSF.severity_critical())

    event
    |> Map.put(:severity_id, severity_id)
    |> Map.put(:severity, OCSF.severity_name(severity_id))
  end

  defp maybe_escalate_edge_anomaly_severity(event, _action), do: event

  defp put_service_radar_metadata(event, key, value) do
    metadata = fetch_attr(event, :metadata) || %{}
    service_radar = map_value(metadata, "service_radar") || %{}

    metadata = Map.put(metadata, "service_radar", Map.put(service_radar, key, value))

    Map.put(event, :metadata, metadata)
  end

  defp put_unmapped_value(event, key, value) do
    unmapped = event_unmapped(event)
    Map.put(event, :unmapped, Map.put(unmapped, key, value))
  end

  @doc false
  @spec seasonal_disposition_action(map() | nil) :: :suppress | :escalate | :pass_through
  def seasonal_disposition_action(%{disposition: disposition, status: status})
      when disposition in ["normal", "suppress"] or status in ["normal", "suppressed"] do
    :suppress
  end

  def seasonal_disposition_action(%{disposition: disposition, status: status})
      when disposition in ["seasonal_breach", "breach", "off_baseline", "anomalous"] or
             status in ["breach", "anomaly_open", "anomalous", "off_baseline"] do
    :escalate
  end

  def seasonal_disposition_action(_disposition), do: :pass_through

  defp emit_anomaly_disposition_telemetry(action, attrs, disposition) do
    :telemetry.execute(
      [:serviceradar, :observability, :stateful_alert_engine, :anomaly_disposition],
      %{count: 1},
      %{
        action: action,
        series_key: map_value(attrs, :series_key),
        metric_class: map_value(attrs, :metric_class),
        reason: map_value(attrs, :reason),
        seasonal_disposition: map_value(disposition || %{}, :disposition),
        seasonal_status: map_value(disposition || %{}, :status)
      }
    )
  end
end
