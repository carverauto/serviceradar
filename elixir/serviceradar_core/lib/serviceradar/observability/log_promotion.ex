defmodule ServiceRadar.Observability.LogPromotion do
  @moduledoc """
  Promotion pipeline from logs to OCSF events using per-deployment rules.
  """

  require Logger
  require Ash.Query

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.EventWriter.OCSF
  alias ServiceRadar.Monitoring.AlertGenerator
  alias ServiceRadar.Observability.{EventRule, StatefulAlertEngine}
  alias UUID

  import Ash.Expr

  @severity_text_map %{
    "fatal" => OCSF.severity_fatal(),
    "critical" => OCSF.severity_critical(),
    "high" => OCSF.severity_high(),
    "error" => OCSF.severity_high(),
    "warn" => OCSF.severity_medium(),
    "warning" => OCSF.severity_medium(),
    "info" => OCSF.severity_informational(),
    "debug" => OCSF.severity_low(),
    "trace" => OCSF.severity_low()
  }

  @spec promote([map()]) :: {:ok, non_neg_integer()}
  def promote(rows) when is_list(rows) do
    # DB connection's search_path determines the schema
    rules = load_rules()
    promotions = build_promotions(rows, rules)
    events = Enum.map(promotions, & &1.event)

    case insert_events(events) do
      {:ok, 0} ->
        {:ok, 0}

      {:ok, count} ->
        _ = maybe_evaluate_stateful_rules(events)
        maybe_create_alerts(promotions)
        Logger.debug("Promoted #{count} logs to OCSF events")
        {:ok, count}
    end
  rescue
    error ->
      Logger.warning("Log promotion failed: #{inspect(error)}")
      {:ok, 0}
  end

  defp load_rules do
    # DB connection's search_path determines the schema
    actor = SystemActor.system(:log_promotion)

    EventRule
    |> Ash.Query.for_read(:active, %{})
    |> Ash.Query.filter(expr(source_type == :log))
    |> Ash.read(actor: actor)
    |> unwrap_page()
  rescue
    error ->
      Logger.warning("Failed to load log promotion rules: #{inspect(error)}")
      []
  end

  defp unwrap_page({:ok, %Ash.Page.Keyset{results: results}}), do: results
  defp unwrap_page({:ok, results}) when is_list(results), do: results
  defp unwrap_page(_), do: []

  defp build_promotions(_rows, []), do: []

  defp build_promotions(rows, rules) do
    Enum.flat_map(rows, &match_rules(&1, rules))
  end

  defp insert_events([]), do: {:ok, 0}

  defp insert_events(events) do
    # DB connection's search_path determines the schema
    {count, _} =
      ServiceRadar.Repo.insert_all(
        "ocsf_events",
        events,
        on_conflict: :nothing,
        returning: false
      )

    if count > 0 do
      ServiceRadar.Events.PubSub.broadcast_event(%{count: count})
    end

    :telemetry.execute(
      [:serviceradar, :log_promotion, :events_created],
      %{count: count},
      %{}
    )

    {:ok, count}
  end

  defp match_rules(log, rules) do
    case Enum.find(rules, &rule_matches?(log, &1)) do
      nil ->
        []

      rule ->
        event = build_event(log, rule)
        [%{event: event, alert: alert_config(event, rule)}]
    end
  end

  defp rule_matches?(log, %EventRule{match: match}) when is_map(match) do
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
        match_event_type(attributes, match) and
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
      nil ->
        true

      needle when is_binary(needle) ->
        body = Map.get(log, :body) || ""
        String.contains?(String.downcase(body), String.downcase(needle))

      _ ->
        false
    end
  end

  defp match_event_type(attributes, match) do
    case match["event_type"] do
      nil ->
        true

      expected ->
        actual =
          get_nested_value(attributes, "event_type") ||
            get_nested_value(attributes, "event.type") ||
            Map.get(attributes, "event_type") ||
            Map.get(attributes, :event_type) ||
            Map.get(attributes, "event.type")

        match_value(actual, expected)
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

  defp build_event(log, %EventRule{} = rule) do
    event_overrides = rule.event || %{}
    log_time = event_log_time(log)
    subject = ingest_subject(log)

    {severity_id, severity_name} = resolve_severity(log, event_overrides)
    {activity_id, class_uid, category_uid, type_uid} = event_uids(event_overrides)
    status_id = event_status_id(event_overrides)

    %{
      id: Ecto.UUID.bingenerate(),
      time: log_time,
      class_uid: class_uid,
      category_uid: category_uid,
      type_uid: type_uid,
      activity_id: activity_id,
      activity_name: OCSF.log_activity_name(activity_id),
      severity_id: severity_id,
      severity: severity_name,
      message: event_message(event_overrides, log),
      status_id: status_id,
      status: event_status(event_overrides, status_id),
      status_code: event_overrides["status_code"],
      status_detail: event_overrides["status_detail"],
      metadata: build_metadata(log, rule, subject),
      observables: event_overrides["observables"] || [],
      trace_id: Map.get(log, :trace_id),
      span_id: Map.get(log, :span_id),
      actor: event_actor(event_overrides, log),
      device: event_overrides["device"] || %{},
      src_endpoint: event_overrides["src_endpoint"] || %{},
      dst_endpoint: event_overrides["dst_endpoint"] || %{},
      log_name: event_log_name(event_overrides, subject, log),
      log_provider: event_log_provider(event_overrides, log),
      log_level: event_log_level(event_overrides, log),
      log_version: event_overrides["log_version"],
      unmapped: build_unmapped(log, rule),
      raw_data: nil,
      created_at: DateTime.utc_now()
    }
  end

  defp maybe_create_alerts(promotions) do
    {created, attempted} =
      Enum.reduce(promotions, {0, 0}, fn promotion, acc ->
        update_alert_counts(promotion, acc)
      end)

    maybe_emit_alert_metrics(created, attempted)
  end

  defp alert_config(event, %EventRule{} = rule) do
    case rule.event do
      %{"alert" => false} -> nil
      %{"alert" => true} -> %{}
      %{"alert" => %{} = config} -> config
      _ -> if Map.get(event, :severity_id, 0) >= OCSF.severity_high(), do: %{}, else: nil
    end
  end

  defp maybe_evaluate_stateful_rules([]), do: :ok

  defp maybe_evaluate_stateful_rules(events) do
    case StatefulAlertEngine.evaluate_events(events) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Stateful alert evaluation failed: #{inspect(reason)}")
        :ok
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
    Map.get(@severity_text_map, String.downcase(text), OCSF.severity_unknown())
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

  defp event_message(overrides, log) do
    overrides["message"] || Map.get(log, :body) || "Log promotion event"
  end

  defp event_status_id(overrides) do
    override_int(overrides["status_id"]) || OCSF.status_success()
  end

  defp event_status(overrides, status_id) do
    overrides["status"] || OCSF.status_name(status_id)
  end

  defp event_actor(overrides, log) do
    overrides["actor"] || OCSF.build_actor(app_name: Map.get(log, :service_name))
  end

  defp event_log_name(overrides, subject, log) do
    overrides["log_name"] || subject || Map.get(log, :service_name) || "logs"
  end

  defp event_log_provider(overrides, log) do
    overrides["log_provider"] || Map.get(log, :service_name) || "unknown"
  end

  defp event_log_level(overrides, log) do
    overrides["log_level"] || Map.get(log, :severity_text)
  end

  defp event_log_time(log) do
    Map.get(log, :timestamp) || DateTime.utc_now()
  end

  defp event_uids(overrides) do
    activity_id = override_int(overrides["activity_id"]) || OCSF.activity_log_create()
    class_uid = override_int(overrides["class_uid"]) || OCSF.class_event_log_activity()
    category_uid = override_int(overrides["category_uid"]) || OCSF.category_system_activity()
    type_uid = override_int(overrides["type_uid"]) || OCSF.type_uid(class_uid, activity_id)

    {activity_id, class_uid, category_uid, type_uid}
  end

  defp update_alert_counts(%{event: _event, alert: nil}, counts), do: counts

  defp update_alert_counts(%{event: event, alert: alert_config}, {created, attempted}) do
    # DB connection's search_path determines the schema
    case AlertGenerator.from_event(event, alert: alert_config) do
      {:ok, %{} = _alert} -> {created + 1, attempted + 1}
      _ -> {created, attempted + 1}
    end
  end

  defp maybe_emit_alert_metrics(_created, 0), do: :ok

  defp maybe_emit_alert_metrics(created, attempted) do
    :telemetry.execute(
      [:serviceradar, :log_promotion, :alerts_created],
      %{count: created, attempted: attempted},
      %{}
    )
  end
end
