defmodule ServiceRadar.Observability.StatefulAlertEngine.RuleMatcher do
  @moduledoc """
  Predicate matching of a rule's `match` clause against a log/event/metric
  record: the per-signal `rule_matches_*?/2` entry points, the field/severity/
  subject/body comparators, and the generic `match_map/2` and `match_value/2`
  primitives shared across signals.

  Pure functions; no snapshot or DB state is touched here.
  """

  import ServiceRadar.Observability.StatefulAlertEngine.Helpers
  import ServiceRadar.Observability.StatefulAlertEngine.Record

  def rule_matches_log?(log, rule) do
    match = rule.match || %{}

    if match["always"] == true do
      true
    else
      log_matches?(log, match)
    end
  end

  def rule_matches_event?(event, rule) do
    match = rule.match || %{}

    if match["always"] == true do
      true
    else
      event_matches?(event, match)
    end
  end

  def rule_recovers_event?(event, rule) do
    case rule.match || %{} do
      %{"recovery" => recovery} when is_map(recovery) -> event_matches?(event, recovery)
      _ -> false
    end
  end

  def rule_matches_metric?(metric, rule) do
    match = rule.match || %{}

    if match["always"] == true do
      true
    else
      metric_matches?(metric, match)
    end
  end

  def anomaly_open_rule?(%{signal: :event, match: %{} = match}) do
    attrs = Map.get(match, "attribute_equals") || %{}

    match_subject_prefix? =
      case Map.get(match, "subject_prefix") do
        prefix when is_binary(prefix) ->
          String.starts_with?("signals.analytics.predictions", prefix)

        _ ->
          false
      end

    match_subject_prefix? and
      match_value("anomaly", Map.get(attrs, "event_type")) and
      match_value("anomaly_open", Map.get(attrs, "anomaly.state"))
  end

  def anomaly_open_rule?(_rule), do: false

  def log_matches?(log, match) do
    subject = ingest_subject(log)
    attributes = Map.get(log, :attributes) || %{}
    resource_attributes = Map.get(log, :resource_attributes) || %{}

    Enum.all?([
      match_subject_prefix(subject, match),
      match_service_name_value(fetch_attr(log, :service_name), match),
      match_severity_values(
        fetch_attr(log, :severity_number),
        fetch_attr(log, :severity_text),
        match
      ),
      match_body_value(fetch_attr(log, :body), match),
      match_map(attributes, match["attribute_equals"]),
      match_map(resource_attributes, match["resource_attribute_equals"])
    ])
  end

  def event_matches?(event, match) do
    {attributes, resource_attributes} = event_match_sources(event)

    Enum.all?([
      match_subject_prefix(fetch_attr(event, :log_name), match),
      match_service_name_value(fetch_attr(event, :log_provider), match),
      match_severity_values(fetch_attr(event, :severity_id), fetch_attr(event, :severity), match),
      match_body_value(fetch_attr(event, :message), match),
      match_map(attributes, match["attribute_equals"]),
      match_map(resource_attributes, match["resource_attribute_equals"])
    ])
  end

  def metric_matches?(metric, match) do
    {attributes, resource_attributes} = metric_match_sources(metric)

    Enum.all?([
      match_metric_field(metric, :metric_name, match["metric_name"]),
      match_metric_field(metric, :metric_type, match["metric_type"]),
      match_metric_field(metric, :unit, match["unit"]),
      match_metric_field(metric, :device_id, match["device_id"]),
      match_metric_field(metric, :agent_id, match["agent_id"]),
      match_metric_field(metric, :gateway_id, match["gateway_id"]),
      match_metric_field(metric, :partition, match["partition"]),
      match_metric_field(metric, :series_key, match["series_key"]),
      match_map(fetch_attr(metric, :tags) || %{}, match["tag_equals"]),
      match_map(fetch_attr(metric, :metadata) || %{}, match["metadata_equals"]),
      match_map(attributes, match["attribute_equals"]),
      match_map(resource_attributes, match["resource_attribute_equals"])
    ])
  end

  def match_metric_field(_metric, _field, nil), do: true

  def match_metric_field(metric, field, expected),
    do: match_value(fetch_attr(metric, field), expected)

  def match_subject_prefix(_subject, match) when map_size(match) == 0, do: false

  def match_subject_prefix(subject, match) do
    case match["subject_prefix"] do
      nil -> true
      prefix when is_binary(prefix) and is_binary(subject) -> String.starts_with?(subject, prefix)
      _ -> false
    end
  end

  def match_service_name_value(value, match) do
    case match["service_name"] do
      nil -> true
      expected -> match_value(value, expected)
    end
  end

  def match_severity_values(severity_number, severity_text, match) do
    min = match["severity_number_min"]
    max = match["severity_number_max"]
    text = match["severity_text"]

    matches_min =
      if is_number(min) and is_number(severity_number) do
        severity_number >= min
      else
        true
      end

    matches_max =
      if is_number(max) and is_number(severity_number) do
        severity_number <= max
      else
        true
      end

    matches_text =
      if is_nil(text) do
        true
      else
        match_value(severity_text, text)
      end

    matches_min and matches_max and matches_text
  end

  def match_body_value(body, match) do
    case match["body_contains"] do
      nil ->
        true

      needle when is_binary(needle) ->
        body = body || ""
        String.contains?(String.downcase(body), String.downcase(needle))

      _ ->
        false
    end
  end

  def match_map(_source, nil), do: true
  def match_map(_source, %{} = match) when map_size(match) == 0, do: true

  def match_map(source, %{} = match) do
    Enum.all?(match, fn {key, value} ->
      actual = get_nested_value(source, key)
      match_value(actual, value)
    end)
  end

  def match_map(_source, _match), do: false

  def match_value(actual, expected) when is_list(expected) do
    Enum.any?(expected, &match_value(actual, &1))
  end

  def match_value(actual, expected) when is_binary(actual) and is_binary(expected) do
    String.downcase(actual) == String.downcase(expected)
  end

  def match_value(actual, expected), do: actual == expected

  def ingest_subject(log) do
    attributes = Map.get(log, :attributes, %{})

    get_nested_value(attributes, "serviceradar.ingest.subject") ||
      attributes |> get_nested_value("serviceradar.ingest") |> get_nested_value("subject")
  end
end
