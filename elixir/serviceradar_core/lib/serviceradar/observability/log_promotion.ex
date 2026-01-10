defmodule ServiceRadar.Observability.LogPromotion do
  @moduledoc """
  Promotion pipeline from logs to OCSF events using per-tenant rules.
  """

  require Logger

  alias ServiceRadar.EventWriter.OCSF
  alias ServiceRadar.Monitoring.AlertGenerator
  alias ServiceRadar.Observability.LogPromotionRule
  alias UUID

  @spec promote([map()], String.t() | nil, String.t() | nil) :: {:ok, non_neg_integer()}
  def promote(_rows, nil, _schema), do: {:ok, 0}
  def promote(_rows, _tenant_id, nil), do: {:ok, 0}

  def promote(rows, tenant_id, schema) when is_list(rows) do
    rules = load_rules(schema)

    if rules == [] do
      {:ok, 0}
    else
      promotions =
        rows
        |> Enum.flat_map(&match_rules(&1, rules))

      events = Enum.map(promotions, & &1.event)

      if events == [] do
        {:ok, 0}
      else
        {count, _} =
          ServiceRadar.Repo.insert_all("ocsf_events", events,
            prefix: schema,
            on_conflict: :nothing,
            returning: false
          )

        :telemetry.execute(
          [:serviceradar, :log_promotion, :events_created],
          %{count: count},
          %{tenant_id: tenant_id}
        )

        maybe_create_alerts(promotions, schema)
        Logger.debug("Promoted #{count} logs to OCSF events", tenant_id: tenant_id)
        {:ok, count}
      end
    end
  rescue
    error ->
      Logger.warning("Log promotion failed: #{inspect(error)}", tenant_id: tenant_id)
      {:ok, 0}
  end

  defp load_rules(schema) do
    LogPromotionRule
    |> Ash.Query.for_read(:active, %{}, tenant: schema)
    |> Ash.read(authorize?: false)
    |> unwrap_page()
  rescue
    error ->
      Logger.warning("Failed to load log promotion rules: #{inspect(error)}")
      []
  end

  defp unwrap_page({:ok, %Ash.Page.Keyset{results: results}}), do: results
  defp unwrap_page({:ok, results}) when is_list(results), do: results
  defp unwrap_page(_), do: []

  defp match_rules(log, rules) do
    case Enum.find(rules, &rule_matches?(log, &1)) do
      nil -> []
      rule ->
        event = build_event(log, rule)
        [%{event: event, alert: alert_config(event, rule)}]
    end
  end

  defp rule_matches?(log, %LogPromotionRule{match: match}) when is_map(match) do
    if match["always"] == true do
      true
    else
      subject = ingest_subject(log)
      attributes = Map.get(log, :attributes) || %{}
      resource_attributes = Map.get(log, :resource_attributes) || %{}

      match_subject_prefix(subject, match) and
        match_service_name(log, match) and
        match_severity(log, match) and
        match_body(log, match) and
        match_map(attributes, match["attribute_equals"]) and
        match_map(resource_attributes, match["resource_attribute_equals"])
    end
  end

  defp rule_matches?(_log, _rule), do: false

  defp match_subject_prefix(_subject, match) when map_size(match) == 0, do: false

  defp match_subject_prefix(subject, match) do
    case match["subject_prefix"] do
      nil -> true
      prefix when is_binary(prefix) and is_binary(subject) -> String.starts_with?(subject, prefix)
      _ -> false
    end
  end

  defp match_service_name(log, match) do
    case match["service_name"] do
      nil -> true
      value -> match_value(Map.get(log, :service_name), value)
    end
  end

  defp match_severity(log, match) do
    min = match["severity_number_min"]
    max = match["severity_number_max"]
    text = match["severity_text"]

    severity_number = Map.get(log, :severity_number)
    severity_text = Map.get(log, :severity_text)

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

  defp match_body(log, match) do
    case match["body_contains"] do
      nil -> true
      needle when is_binary(needle) ->
        body = Map.get(log, :body) || ""
        String.contains?(String.downcase(body), String.downcase(needle))
      _ -> false
    end
  end

  defp match_map(_source, nil), do: true
  defp match_map(_source, %{} = match) when map_size(match) == 0, do: true

  defp match_map(source, %{} = match) do
    Enum.all?(match, fn {key, value} ->
      actual = get_nested_value(source, key)
      match_value(actual, value)
    end)
  end

  defp match_map(_source, _match), do: false

  defp match_value(actual, expected) when is_list(expected) do
    Enum.any?(expected, &match_value(actual, &1))
  end

  defp match_value(actual, expected) when is_binary(actual) and is_binary(expected) do
    String.downcase(actual) == String.downcase(expected)
  end

  defp match_value(actual, expected), do: actual == expected

  defp get_nested_value(map, key) when is_map(map) and is_binary(key) do
    key
    |> String.split(".")
    |> Enum.reduce(map, fn segment, acc ->
      if is_map(acc), do: Map.get(acc, segment), else: nil
    end)
  end

  defp get_nested_value(map, key) when is_map(map), do: Map.get(map, key)
  defp get_nested_value(_, _), do: nil

  defp ingest_subject(log) do
    get_nested_value(Map.get(log, :attributes, %{}), "serviceradar.ingest.subject")
  end

  defp build_event(log, %LogPromotionRule{} = rule) do
    event_overrides = rule.event || %{}
    log_time = Map.get(log, :timestamp) || DateTime.utc_now()
    subject = ingest_subject(log)

    {severity_id, severity_name} = resolve_severity(log, event_overrides)
    activity_id = override_int(event_overrides["activity_id"]) || OCSF.activity_log_create()
    class_uid = override_int(event_overrides["class_uid"]) || OCSF.class_event_log_activity()
    category_uid = override_int(event_overrides["category_uid"]) || OCSF.category_system_activity()
    type_uid = override_int(event_overrides["type_uid"]) || OCSF.type_uid(class_uid, activity_id)

    %{
      id: UUID.uuid4(),
      time: log_time,
      class_uid: class_uid,
      category_uid: category_uid,
      type_uid: type_uid,
      activity_id: activity_id,
      activity_name: OCSF.log_activity_name(activity_id),
      severity_id: severity_id,
      severity: severity_name,
      message: event_overrides["message"] || Map.get(log, :body) || "Log promotion event",
      status_id: override_int(event_overrides["status_id"]) || OCSF.status_success(),
      status: event_overrides["status"] || OCSF.status_name(override_int(event_overrides["status_id"]) || 1),
      status_code: event_overrides["status_code"],
      status_detail: event_overrides["status_detail"],
      metadata: build_metadata(log, rule, subject),
      observables: event_overrides["observables"] || [],
      trace_id: Map.get(log, :trace_id),
      span_id: Map.get(log, :span_id),
      actor: event_overrides["actor"] || OCSF.build_actor(app_name: Map.get(log, :service_name)),
      device: event_overrides["device"] || %{},
      src_endpoint: event_overrides["src_endpoint"] || %{},
      dst_endpoint: event_overrides["dst_endpoint"] || %{},
      log_name: event_overrides["log_name"] || subject || Map.get(log, :service_name) || "logs",
      log_provider: event_overrides["log_provider"] || Map.get(log, :service_name) || "unknown",
      log_level: event_overrides["log_level"] || Map.get(log, :severity_text),
      log_version: event_overrides["log_version"],
      unmapped: build_unmapped(log, rule),
      raw_data: nil,
      tenant_id: Map.get(log, :tenant_id),
      created_at: DateTime.utc_now()
    }
  end

  defp maybe_create_alerts(promotions, schema) do
    {created, attempted} =
      Enum.reduce(promotions, {0, 0}, fn %{event: event, alert: alert_config}, {created, attempted} ->
        if alert_config do
          result = AlertGenerator.from_event(event, alert: alert_config, tenant: schema)

          created =
            case result do
              {:ok, %{} = _alert} -> created + 1
              _ -> created
            end

          {created, attempted + 1}
        else
          {created, attempted}
        end
      end)

    if attempted > 0 do
      :telemetry.execute(
        [:serviceradar, :log_promotion, :alerts_created],
        %{count: created, attempted: attempted},
        %{}
      )
    end
  end

  defp alert_config(event, %LogPromotionRule{} = rule) do
    case rule.event do
      %{"alert" => false} -> nil
      %{"alert" => true} -> %{}
      %{"alert" => %{} = config} -> config
      _ -> if Map.get(event, :severity_id, 0) >= OCSF.severity_high(), do: %{}, else: nil
    end
  end

  defp build_metadata(log, rule, subject) do
    provenance = %{
      source_log_id: Map.get(log, :id),
      source_log_timestamp: Map.get(log, :timestamp),
      source_subject: subject,
      rule_id: rule.id,
      rule_name: rule.name
    }

    OCSF.build_metadata(
      version: "1.7.0",
      correlation_uid: Map.get(log, :id),
      original_time: Map.get(log, :timestamp)
    )
    |> Map.put(:serviceradar, provenance)
  end

  defp build_unmapped(log, rule) do
    %{
      log_attributes: Map.get(log, :attributes) || %{},
      log_resource_attributes: Map.get(log, :resource_attributes) || %{},
      rule_match: rule.match || %{}
    }
  end

  defp resolve_severity(log, overrides) do
    cond do
      is_number(overrides["severity_id"]) ->
        {overrides["severity_id"], OCSF.severity_name(overrides["severity_id"])}

      is_binary(overrides["severity"]) ->
        severity_id = severity_from_text(overrides["severity"])
        {severity_id, OCSF.severity_name(severity_id)}

      true ->
        severity_id = severity_from_log(log)
        {severity_id, OCSF.severity_name(severity_id)}
    end
  end

  defp severity_from_log(log) do
    case Map.get(log, :severity_number) do
      number when is_number(number) -> severity_from_otel_number(number)
      _ -> severity_from_text(Map.get(log, :severity_text))
    end
  end

  defp severity_from_text(text) when is_binary(text) do
    case String.downcase(text) do
      "fatal" -> OCSF.severity_fatal()
      "critical" -> OCSF.severity_critical()
      "high" -> OCSF.severity_high()
      "error" -> OCSF.severity_high()
      "warn" -> OCSF.severity_medium()
      "warning" -> OCSF.severity_medium()
      "info" -> OCSF.severity_informational()
      "debug" -> OCSF.severity_low()
      "trace" -> OCSF.severity_low()
      _ -> OCSF.severity_unknown()
    end
  end

  defp severity_from_text(_), do: OCSF.severity_unknown()

  defp severity_from_otel_number(number) when is_number(number) do
    cond do
      number >= 21 -> OCSF.severity_fatal()
      number >= 17 -> OCSF.severity_high()
      number >= 13 -> OCSF.severity_medium()
      number >= 9 -> OCSF.severity_informational()
      number >= 5 -> OCSF.severity_low()
      number >= 1 -> OCSF.severity_low()
      true -> OCSF.severity_unknown()
    end
  end

  defp severity_from_otel_number(_), do: OCSF.severity_unknown()

  defp override_int(value) when is_integer(value), do: value

  defp override_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> nil
    end
  end

  defp override_int(_), do: nil
end
