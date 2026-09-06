defmodule ServiceRadar.Observability.LogPromotion do
  @moduledoc """
  Promotion pipeline from logs to OCSF events using per-deployment rules.
  """

  import Ash.Expr

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.EventWriter.BulkInsert
  alias ServiceRadar.EventWriter.FalcoDecomposition
  alias ServiceRadar.EventWriter.OCSF
  alias ServiceRadar.Monitoring.AlertGenerator
  alias ServiceRadar.Observability.EventRule
  alias ServiceRadar.Observability.StatefulAlertEngine
  alias ServiceRadar.Observability.StatefulAlertEvaluationQueue

  require Ash.Query
  require Logger

  @rules_cache_key {__MODULE__, :active_log_rules}
  @default_rule_cache_ttl_ms 5_000
  @binary_log_id_prefix "urn:serviceradar:log-id:binary:v1:"
  @escaped_text_log_id_prefix "urn:serviceradar:log-id:text:v1:"

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

  @spec promote([map()], keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def promote(rows, opts \\ []) when is_list(rows) do
    # DB connection's search_path determines the schema
    with {:ok, rules} <- active_log_rules() do
      promotions = build_promotions(rows, rules)
      events = Enum.map(promotions, & &1.event)

      case insert_events(events) do
        {:ok, 0} ->
          {:ok, 0}

        {:ok, count} ->
          with :ok <-
                 evaluate_and_create_alerts(
                   events,
                   promotions,
                   Keyword.get(opts, :stateful_evaluation, :async)
                 ) do
            Logger.debug("Promoted #{count} logs to OCSF events")
            {:ok, count}
          end
      end
    end
  rescue
    error ->
      Logger.warning("Log promotion failed: #{inspect(error)}")
      {:error, error}
  end

  @doc """
  Clears this node's active log-promotion rule cache.

  EventRule mutations call this after successful create/update/delete so the
  node that handled the mutation sees rule changes immediately. Other clustered
  nodes refresh independently when their short TTL expires.
  """
  @spec invalidate_rules_cache() :: :ok
  def invalidate_rules_cache do
    _ = :persistent_term.erase(@rules_cache_key)
    :ok
  end

  @doc false
  def active_log_rules(load_fun \\ &load_rules/0) when is_function(load_fun, 0) do
    now_ms = System.monotonic_time(:millisecond)

    case cached_rules() do
      {expires_at_ms, rules} when expires_at_ms > now_ms ->
        {:ok, rules}

      _ ->
        with {:ok, rules} <- load_fun.() do
          :persistent_term.put(@rules_cache_key, {now_ms + rule_cache_ttl_ms(), rules})
          {:ok, rules}
        end
    end
  end

  defp cached_rules do
    :persistent_term.get(@rules_cache_key, :miss)
  end

  defp rule_cache_ttl_ms do
    Application.get_env(
      :serviceradar_core,
      :log_promotion_rule_cache_ttl_ms,
      @default_rule_cache_ttl_ms
    )
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
      {:error, error}
  end

  defp unwrap_page({:ok, %Ash.Page.Keyset{results: results}}), do: {:ok, results}
  defp unwrap_page({:ok, results}) when is_list(results), do: {:ok, results}
  defp unwrap_page({:error, _} = error), do: error

  defp build_promotions(_rows, []), do: []

  defp build_promotions(rows, rules) do
    Enum.flat_map(rows, &match_rules(&1, rules))
  end

  defp insert_events([]), do: {:ok, 0}

  defp insert_events(events) do
    # DB connection's search_path determines the schema
    {count, _} =
      BulkInsert.insert_all(
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
    match["always"] == true or rule_matches_all?(log, match)
  end

  defp rule_matches?(_log, _rule), do: false

  defp rule_matches_all?(log, match) do
    subject = ingest_subject(log)
    attributes = Map.get(log, :attributes) || %{}
    resource_attributes = Map.get(log, :resource_attributes) || %{}

    Enum.all?([
      match_subject_prefix(subject, match),
      match_service_name(log, match),
      match_severity(log, match),
      match_body(log, match),
      match_event_type(attributes, match),
      match_map(attributes, match["attribute_equals"]),
      match_map(resource_attributes, match["resource_attribute_equals"])
    ])
  end

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
    case Map.get(map, key) do
      nil ->
        key
        |> String.split(".")
        |> Enum.reduce(map, &nested_map_get/2)

      value ->
        value
    end
  end

  defp get_nested_value(map, key) when is_map(map), do: Map.get(map, key)
  defp get_nested_value(_, _), do: nil

  defp nested_map_get(segment, acc) when is_map(acc), do: Map.get(acc, segment)
  defp nested_map_get(_, _), do: nil

  defp ingest_subject(log) do
    attributes = Map.get(log, :attributes, %{})

    get_nested_value(attributes, "serviceradar.ingest.subject") ||
      attributes |> get_nested_value("serviceradar.ingest") |> get_nested_value("subject")
  end

  defp build_event(log, %EventRule{} = rule) do
    event_overrides = rule.event || %{}
    log_time = event_log_time(log)
    subject = ingest_subject(log)

    {severity_id, severity_name} = resolve_severity(log, event_overrides)
    {activity_id, class_uid, category_uid, type_uid} = event_uids(event_overrides)
    status_id = event_status_id(event_overrides)

    event = %{
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
      device: event_device(event_overrides, log),
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

    enrich_security_signal_event(event, log)
  end

  defp enrich_security_signal_event(event, log) do
    attributes = Map.get(log, :attributes) || %{}

    cond do
      get_nested_value(attributes, "event_type") == "waf.finding" ->
        enrich_waf_finding_event(event, attributes)

      is_map(get_nested_value(attributes, "falco")) ->
        enrich_falco_event(event, log, attributes)

      true ->
        event
    end
  end

  defp enrich_waf_finding_event(event, attributes) do
    waf = get_nested_value(attributes, "waf") || %{}
    client_ip = get_nested_value(waf, "client_ip")
    rule_id = get_nested_value(waf, "rule_id")
    request_path = get_nested_value(waf, "request_path")
    request_id = get_nested_value(waf, "request_id")

    source =
      get_nested_value(waf, "source") || get_nested_value(attributes, "security.signal.source")

    event
    |> Map.put(:src_endpoint, OCSF.build_endpoint(ip: client_ip))
    |> Map.put(:observables, waf_observables(client_ip, rule_id, request_path))
    |> update_in([:metadata], &put_security_signal_metadata(&1, "waf", source, request_id))
    |> update_in([:unmapped], &put_waf_unmapped(&1, waf))
  end

  defp waf_observables(client_ip, rule_id, request_path) do
    []
    |> maybe_add_observable(client_ip, &OCSF.ip_observable/1)
    |> maybe_add_observable(rule_id, &OCSF.build_observable(&1, "WAF Rule ID", 99))
    |> maybe_add_observable(request_path, &OCSF.build_observable(&1, "URL Path", 99))
    |> Enum.reverse()
  end

  defp maybe_add_observable(observables, value, _builder) when value in [nil, ""], do: observables
  defp maybe_add_observable(observables, value, builder), do: [builder.(value) | observables]

  defp put_security_signal_metadata(metadata, kind, source, request_id) when is_map(metadata) do
    signal =
      %{
        "kind" => kind,
        "source" => source,
        "request_id" => request_id
      }
      |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
      |> Map.new()

    Map.put(metadata, :security_signal, signal)
  end

  defp put_security_signal_metadata(_, kind, source, request_id) do
    put_security_signal_metadata(%{}, kind, source, request_id)
  end

  defp put_waf_unmapped(unmapped, waf) when is_map(unmapped), do: Map.put(unmapped, :waf, waf)
  defp put_waf_unmapped(_, waf), do: %{waf: waf}

  defp enrich_falco_event(event, log, attributes) do
    falco = get_nested_value(attributes, "falco") || %{}
    resource_attributes = Map.get(log, :resource_attributes) || %{}
    output_fields = get_nested_value(falco, "output_fields") || %{}

    hostname =
      get_nested_value(resource_attributes, "host.name") ||
        get_nested_value(output_fields, "hostname") ||
        Map.get(log, :service_instance)

    namespace =
      get_nested_value(resource_attributes, "k8s.namespace.name") ||
        get_nested_value(output_fields, "k8s.ns.name")

    pod =
      get_nested_value(resource_attributes, "k8s.pod.name") ||
        get_nested_value(output_fields, "k8s.pod.name")

    container =
      get_nested_value(resource_attributes, "container.name") ||
        get_nested_value(output_fields, "container.name")

    container_id =
      get_nested_value(resource_attributes, "container.id") ||
        get_nested_value(output_fields, "container.id")

    context =
      FalcoDecomposition.context(falco, output_fields,
        hostname: hostname,
        namespace: namespace,
        pod: pod,
        container: container,
        container_id: container_id
      )

    class_uid = FalcoDecomposition.class_uid(falco, output_fields)
    diagnostics = FalcoDecomposition.diagnostics(falco, output_fields, context)
    finding_info = FalcoDecomposition.finding_info(falco, output_fields, ingest_subject(log))
    attacks = FalcoDecomposition.attacks(falco, output_fields)

    event
    |> Map.put(:class_uid, class_uid)
    |> Map.put(:category_uid, OCSF.category_findings())
    |> Map.put(:activity_id, OCSF.activity_finding_create())
    |> Map.put(:activity_name, OCSF.finding_activity_name(OCSF.activity_finding_create()))
    |> Map.put(:type_uid, OCSF.type_uid(class_uid, OCSF.activity_finding_create()))
    |> Map.put(:observables, FalcoDecomposition.observables(falco, output_fields, context))
    |> update_in(
      [:metadata],
      &put_falco_metadata(&1, falco, context, diagnostics, finding_info, attacks)
    )
    |> update_in(
      [:unmapped],
      &put_falco_unmapped(&1, falco, Map.put(context, "diagnostics", diagnostics))
    )
  end

  defp put_falco_metadata(metadata, falco, context, diagnostics, finding_info, attacks)
       when is_map(metadata) do
    signal =
      FalcoDecomposition.compact_map(%{
        "kind" => "runtime",
        "source" => "falco",
        "rule" => context["rule"],
        "priority" => context["priority"],
        "uuid" => get_nested_value(falco, "uuid"),
        "finding_uid" => finding_info["uid"],
        "attacks" => attacks,
        "diagnostics" => diagnostics
      })

    metadata
    |> Map.put("rule", context["rule"])
    |> Map.put("hostname", context["hostname"])
    |> Map.put("priority", context["priority"])
    |> Map.put("finding_info", finding_info)
    |> Map.put("attacks", attacks)
    |> Map.put(:security_signal, signal)
  end

  defp put_falco_metadata(_, falco, context, diagnostics, finding_info, attacks) do
    put_falco_metadata(%{}, falco, context, diagnostics, finding_info, attacks)
  end

  defp put_falco_unmapped(unmapped, falco, context) when is_map(unmapped) do
    Map.put(unmapped, :falco, Map.merge(falco, context))
  end

  defp put_falco_unmapped(_, falco, context), do: %{falco: Map.merge(falco, context)}

  defp evaluate_and_create_alerts(events, promotions, :async) do
    maybe_create_alerts(promotions)
    maybe_evaluate_stateful_rules(events, :async)
  end

  defp evaluate_and_create_alerts(events, promotions, :sync) do
    with :ok <- maybe_evaluate_stateful_rules(events, :sync) do
      maybe_create_alerts(promotions)
    end
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
      _ -> if Map.get(event, :severity_id, 0) >= OCSF.severity_high(), do: %{}
    end
  end

  defp maybe_evaluate_stateful_rules(events, :sync),
    do: StatefulAlertEngine.evaluate_events(events)

  defp maybe_evaluate_stateful_rules([], :async), do: :ok

  defp maybe_evaluate_stateful_rules(events, :async) do
    case alert_evaluation_queue().enqueue_events(events) do
      :ok ->
        :ok

      {:error, :stateful_alert_evaluation_queue_full} ->
        evaluate_stateful_rules_with_backpressure(events, :stateful_alert_evaluation_queue_full)

      {:error, :stateful_alert_evaluation_queue_unavailable} ->
        evaluate_stateful_rules_with_backpressure(
          events,
          :stateful_alert_evaluation_queue_unavailable
        )

      {:error, reason} ->
        Logger.warning("Stateful alert evaluation enqueue failed", reason: inspect(reason))
        {:error, reason}
    end
  end

  defp evaluate_stateful_rules_with_backpressure(events, queue_reason) do
    Logger.warning("Stateful alert evaluation queue rejected events; evaluating synchronously",
      reason: inspect(queue_reason)
    )

    case StatefulAlertEngine.evaluate_events(events) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Synchronous stateful alert evaluation failed", reason: inspect(reason))
        {:error, reason}
    end
  end

  defp alert_evaluation_queue do
    Application.get_env(
      :serviceradar_core,
      :stateful_alert_evaluation_queue,
      StatefulAlertEvaluationQueue
    )
  end

  defp build_metadata(log, rule, subject) do
    source_log_id = normalize_log_id(Map.get(log, :id))

    provenance = %{
      source_log_id: source_log_id,
      source_log_timestamp: Map.get(log, :timestamp),
      source_subject: subject,
      rule_id: rule.id,
      rule_name: rule.name
    }

    [
      correlation_uid: source_log_id,
      original_time: Map.get(log, :timestamp)
    ]
    |> OCSF.build_metadata()
    |> Map.put(:serviceradar, provenance)
  end

  defp normalize_log_id(id) when is_binary(id) do
    if String.valid?(id), do: escape_reserved_log_id(id), else: encode_binary_log_id(id)
  end

  defp normalize_log_id(id), do: id

  defp escape_reserved_log_id(id) do
    if String.starts_with?(id, [@binary_log_id_prefix, @escaped_text_log_id_prefix]) do
      @escaped_text_log_id_prefix <> Base.url_encode64(id, padding: false)
    else
      id
    end
  end

  defp encode_binary_log_id(id) do
    @binary_log_id_prefix <> Base.encode16(id, case: :lower)
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

  defp event_device(overrides, log) do
    attributes = Map.get(log, :attributes) || %{}

    overrides["device"] ||
      get_nested_value(attributes, "device") ||
      case get_nested_value(attributes, "device_uid") ||
             get_nested_value(attributes, "device.uid") do
        uid when is_binary(uid) and uid != "" -> %{"uid" => uid}
        _ -> %{}
      end
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
