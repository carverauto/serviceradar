defmodule ServiceRadar.Observability.StatefulAlertEngine.Record do
  @moduledoc """
  Reading structured information out of an inbound log/event/metric record:
  timestamps, canonical field lookups, device identity, group-key derivation,
  record classification (log vs event vs metric, engine-generated guard), and
  the attribute/resource-attribute "match sources" used by rule matching.

  All functions are pure extractions over the record map.
  """

  import ServiceRadar.Observability.StatefulAlertEngine.Helpers

  def record_timestamp(record) do
    record_datetime(record, :time) || record_datetime(record, :timestamp) || DateTime.utc_now()
  end

  def record_datetime(record, key) do
    case fetch_attr(record, key) do
      %DateTime{} = dt -> dt
      _ -> nil
    end
  end

  def record_field_value(record, "service_name"),
    do: fetch_attr(record, :service_name) || fetch_attr(record, :log_provider)

  def record_field_value(record, "severity_text"),
    do: fetch_attr(record, :severity_text) || fetch_attr(record, :severity)

  def record_field_value(record, "severity_number"),
    do: fetch_attr(record, :severity_number) || fetch_attr(record, :severity_id)

  def record_field_value(record, "body"),
    do: fetch_attr(record, :body) || fetch_attr(record, :message)

  def record_field_value(record, "log_name"), do: fetch_attr(record, :log_name)
  def record_field_value(record, "log_provider"), do: fetch_attr(record, :log_provider)

  def record_field_value(record, "metric_name"), do: fetch_attr(record, :metric_name)
  def record_field_value(record, "metric_type"), do: fetch_attr(record, :metric_type)
  def record_field_value(record, "unit"), do: fetch_attr(record, :unit)
  def record_field_value(record, "device"), do: record_device_uid(record)
  def record_field_value(record, "device.uid"), do: record_device_uid(record)

  def record_field_value(record, "device_uid"),
    do: fetch_attr(record, :device_uid) || record_device_uid(record)

  def record_field_value(record, "device_id"),
    do: fetch_attr(record, :device_id) || record_device_uid(record)

  def record_field_value(record, "agent_id"), do: fetch_attr(record, :agent_id)
  def record_field_value(record, "gateway_id"), do: fetch_attr(record, :gateway_id)
  def record_field_value(record, "partition"), do: fetch_attr(record, :partition)
  def record_field_value(record, "series_key"), do: fetch_attr(record, :series_key)

  def record_field_value(record, "serviceradar.metric"), do: fetch_attr(record, :metric_name)

  def record_field_value(record, "serviceradar.metric_name"), do: fetch_attr(record, :metric_name)

  def record_field_value(record, "serviceradar.metric_type"), do: fetch_attr(record, :metric_type)

  def record_field_value(record, "serviceradar.device_id"),
    do: fetch_attr(record, :device_id) || record_device_uid(record)

  def record_field_value(record, "serviceradar.device_uid"),
    do: fetch_attr(record, :device_uid) || record_device_uid(record)

  def record_field_value(record, "serviceradar.agent_id"), do: fetch_attr(record, :agent_id)

  def record_field_value(record, "serviceradar.gateway_id"), do: fetch_attr(record, :gateway_id)

  def record_field_value(_record, _key), do: nil

  def record_device(record) do
    case fetch_attr(record, :device) do
      %{} = device -> device
      _ -> %{}
    end
  end

  def record_device_uid(record) do
    record
    |> record_device()
    |> map_value("uid")
  end

  def record_has_time?(record) do
    Map.has_key?(record, :time) || Map.has_key?(record, "time")
  end

  def metric_record?(record) do
    not is_nil(fetch_attr(record, :metric_name)) or
      not is_nil(fetch_attr(record, :metric_type)) or
      Map.has_key?(record, :__stateful_alert_violation__)
  end

  def source_record_details(record) do
    details =
      cond do
        metric_record?(record) -> metric_source_details(record)
        record_has_time?(record) -> event_source_details(record)
        true -> log_source_details(record)
      end

    if synthetic_liveness_check?(record) do
      Map.put(details, "source_synthetic_liveness_check", true)
    else
      details
    end
  end

  def synthetic_liveness_check?(record) do
    metadata = fetch_attr(record, :metadata) || %{}

    service_radar =
      map_value(metadata, "service_radar") || map_value(metadata, "serviceradar") || %{}

    map_value(service_radar, "synthetic_liveness_check") == true
  end

  def event_source_details(record) do
    metadata = fetch_attr(record, :metadata) || %{}

    service_radar =
      map_value(metadata, "service_radar") || map_value(metadata, "serviceradar") || %{}

    unmapped = event_unmapped(record)

    %{
      "source_signal" => "event",
      "source_event_id" => to_string(fetch_attr(record, :id)),
      "source_event_time" => fetch_attr(record, :time),
      "source_log_name" => fetch_attr(record, :log_name),
      "source_log_provider" => fetch_attr(record, :log_provider),
      "source_anomaly_disposition" =>
        map_value(service_radar, "anomaly_disposition") ||
          map_value(unmapped, "anomaly_disposition")
    }
  end

  def log_source_details(record) do
    %{
      "source_signal" => "log",
      "source_log_id" => to_string(fetch_attr(record, :id)),
      "source_log_time" => fetch_attr(record, :timestamp),
      "source_service" => fetch_attr(record, :service_name)
    }
  end

  def metric_source_details(record) do
    condition = fetch_attr(record, :__stateful_alert_condition__) || %{}

    %{
      "source_signal" => "metric",
      "source_metric_time" => fetch_attr(record, :timestamp),
      "source_metric_name" => fetch_attr(record, :metric_name),
      "source_metric_type" => fetch_attr(record, :metric_type),
      "source_metric_value" => fetch_attr(record, :value),
      "source_metric_unit" => fetch_attr(record, :unit),
      "source_metric_device_id" => fetch_attr(record, :device_id),
      "source_metric_agent_id" => fetch_attr(record, :agent_id),
      "source_metric_gateway_id" => fetch_attr(record, :gateway_id),
      "source_metric_partition" => fetch_attr(record, :partition),
      "source_metric_condition" => condition
    }
  end

  def event_match_sources(event) do
    attributes = event_log_attributes(event)
    resource_attributes = event_log_resource_attributes(event)

    attributes =
      if map_size(attributes) == 0 do
        Map.get(event, :unmapped) || Map.get(event, "unmapped") || %{}
      else
        attributes
      end

    resource_attributes =
      if map_size(resource_attributes) == 0 do
        Map.get(event, :metadata) || Map.get(event, "metadata") || %{}
      else
        resource_attributes
      end

    {attributes, resource_attributes}
  end

  def event_log_attributes(event) do
    unmapped = event_unmapped(event)
    Map.get(unmapped, "log_attributes") || Map.get(unmapped, :log_attributes) || %{}
  end

  def event_log_resource_attributes(event) do
    unmapped = event_unmapped(event)

    Map.get(unmapped, "log_resource_attributes") || Map.get(unmapped, :log_resource_attributes) ||
      %{}
  end

  def event_unmapped(event) do
    Map.get(event, :unmapped) || Map.get(event, "unmapped") || %{}
  end

  def metric_match_sources(metric) do
    {metric_match_map(metric), metric_resource_attributes(metric)}
  end

  def metric_match_map(metric) do
    tags = fetch_attr(metric, :tags) || %{}
    metadata = fetch_attr(metric, :metadata) || %{}

    %{
      "metric_name" => fetch_attr(metric, :metric_name),
      "metric_type" => fetch_attr(metric, :metric_type),
      "unit" => fetch_attr(metric, :unit),
      "value" => fetch_attr(metric, :value),
      "device_id" => fetch_attr(metric, :device_id),
      "agent_id" => fetch_attr(metric, :agent_id),
      "gateway_id" => fetch_attr(metric, :gateway_id),
      "partition" => fetch_attr(metric, :partition),
      "series_key" => fetch_attr(metric, :series_key),
      "tags" => tags,
      "metadata" => metadata
    }
  end

  def metric_resource_attributes(metric) do
    %{
      "serviceradar.metric" => fetch_attr(metric, :metric_name),
      "serviceradar.metric_name" => fetch_attr(metric, :metric_name),
      "serviceradar.metric_type" => fetch_attr(metric, :metric_type),
      "serviceradar.device_id" => fetch_attr(metric, :device_id),
      "serviceradar.agent_id" => fetch_attr(metric, :agent_id),
      "serviceradar.gateway_id" => fetch_attr(metric, :gateway_id),
      "serviceradar.partition" => fetch_attr(metric, :partition)
    }
  end

  def stateful_rule_event?(event) do
    metadata = fetch_attr(event, :metadata) || %{}
    serviceradar = fetch_attr(metadata, :serviceradar) || %{}
    fetch_attr(serviceradar, :stateful_rule) == true
  end

  def engine_generated_event?(event) do
    fetch_attr(event, :log_name) == "alert.rule.threshold" and
      fetch_attr(event, :log_provider) == "serviceradar.core"
  end

  def skip_engine_event?(event) do
    stateful_rule_event?(event) or engine_generated_event?(event)
  end

  @doc """
  Substitutes `{key}` placeholders in `template` with values resolved from
  `record` the same way `build_group/2` resolves a group key.

  This is how a rule names its subject in the alert title without putting a
  descriptive value in `group_by`: a group key is the incident identity, so a
  mutable label there strands an open incident when it changes. An
  unresolvable placeholder is left as written rather than rendered blank.
  """
  def render_template(template, record) when is_binary(template) do
    sources = group_sources(record)

    Regex.replace(~r/\{([a-zA-Z0-9_.\-]+)\}/, template, fn placeholder, key ->
      case group_value_for_key(key, record, sources) do
        nil -> placeholder
        value -> to_string(value)
      end
    end)
  end

  def build_group(nil, _log), do: {:ok, "global", %{}}
  def build_group([], _log), do: {:ok, "global", %{}}

  def build_group(keys, record) when is_list(keys) do
    sources = group_sources(record)

    values =
      Enum.reduce(keys, %{}, fn key, acc ->
        value = group_value_for_key(key, record, sources)

        if is_nil(value), do: acc, else: Map.put(acc, key, to_string(value))
      end)

    if map_size(values) == length(keys) do
      group_key =
        Enum.map_join(keys, "|", fn key -> "#{key}=#{Map.get(values, key)}" end)

      {:ok, group_key, values}
    else
      :error
    end
  end

  def group_sources(record) do
    %{
      attributes: Map.get(record, :attributes) || %{},
      resource_attributes: Map.get(record, :resource_attributes) || %{},
      log_attributes: event_log_attributes(record),
      log_resource_attributes: event_log_resource_attributes(record),
      device: record_device(record),
      unmapped: Map.get(record, :unmapped) || %{},
      tags: Map.get(record, :tags) || %{},
      metadata: Map.get(record, :metadata) || %{}
    }
  end

  def group_value_for_key(key, record, sources) do
    sources
    |> group_source_list()
    |> Enum.find_value(fn source -> get_nested_value(source, key) end)
    |> case do
      nil -> record_field_value(record, key)
      value -> value
    end
  end

  def group_source_list(sources) do
    [
      sources.attributes,
      sources.resource_attributes,
      sources.log_attributes,
      sources.log_resource_attributes,
      sources.device,
      sources.unmapped,
      sources.tags,
      sources.metadata
    ]
  end
end
