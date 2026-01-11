defmodule ServiceRadar.Observability.StatefulAlertEngine do
  @moduledoc """
  Bucketed stateful alert evaluation for log/event rules.
  """

  use GenServer

  alias ServiceRadar.Cluster.TenantRegistry
  alias ServiceRadar.EventWriter.OCSF
  alias ServiceRadar.Monitoring.{Alert, AlertGenerator, OcsfEvent, WebhookNotifier}
  alias ServiceRadar.Observability.{
    StatefulAlertRule,
    StatefulAlertRuleHistory,
    StatefulAlertRuleState
  }

  require Logger

  @rules_cache_ms :timer.seconds(60)

  @spec evaluate_logs([map()], String.t(), String.t()) :: :ok | {:error, term()}
  def evaluate_logs(rows, tenant_id, schema) when is_list(rows) do
    with {:ok, _} <- ensure_started(tenant_id, schema) do
      call(tenant_id, {:evaluate_logs, rows})
    end
  end

  @spec evaluate_events([map()], String.t(), String.t()) :: :ok | {:error, term()}
  def evaluate_events(events, tenant_id, schema) when is_list(events) do
    with {:ok, _} <- ensure_started(tenant_id, schema) do
      call(tenant_id, {:evaluate_events, events})
    end
  end

  def start_link(opts) do
    tenant_id = Keyword.fetch!(opts, :tenant_id)
    schema = Keyword.fetch!(opts, :schema)

    GenServer.start_link(__MODULE__, %{tenant_id: tenant_id, schema: schema},
      name: via_tuple(tenant_id)
    )
  end

  @impl true
  def init(state) do
    table = :ets.new(:stateful_alert_rule_state, [:set, :private])
    state = Map.merge(state, %{table: table, rules: [], rules_loaded_at: nil})

    load_state_snapshots(state)

    {:ok, state}
  end

  @impl true
  def handle_call({:evaluate_logs, rows}, _from, state) do
    {state, rules} = load_rules_if_needed(state)

    Enum.each(rows, fn log ->
      Enum.each(rules, fn rule ->
        if rule.signal == :log and rule_matches_log?(log, rule) do
          process_log(rule, log, state)
        end
      end)
    end)

    {:reply, :ok, state}
  rescue
    error ->
      Logger.warning("Stateful alert evaluation failed: #{inspect(error)}")
      {:reply, {:error, error}, state}
  end

  @impl true
  def handle_call({:evaluate_events, events}, _from, state) do
    {state, rules} = load_rules_if_needed(state)

    Enum.each(events, fn event ->
      if skip_engine_event?(event) do
        :ok
      else
        Enum.each(rules, fn rule ->
          if rule.signal == :event and rule_matches_event?(event, rule) do
            process_event(rule, event, state)
          end
        end)
      end
    end)

    {:reply, :ok, state}
  rescue
    error ->
      Logger.warning("Stateful alert evaluation failed: #{inspect(error)}")
      {:reply, {:error, error}, state}
  end

  defp call(tenant_id, message) do
    GenServer.call(via_tuple(tenant_id), message, :timer.seconds(15))
  catch
    :exit, {:noproc, _} ->
      {:error, :engine_not_running}
  end

  defp ensure_started(tenant_id, schema) do
    with {:ok, _} <- TenantRegistry.ensure_registry(tenant_id) do
      case lookup_engine(tenant_id) do
        nil ->
          child_spec = %{
            id: {:stateful_alert_engine, tenant_id},
            start: {__MODULE__, :start_link, [[tenant_id: tenant_id, schema: schema]]},
            restart: :permanent,
            type: :worker
          }

          case TenantRegistry.start_child(tenant_id, child_spec) do
            {:ok, pid} -> {:ok, pid}
            {:error, {:already_started, pid}} -> {:ok, pid}
            {:error, reason} -> {:error, reason}
          end

        pid ->
          {:ok, pid}
      end
    end
  end

  defp lookup_engine(tenant_id) do
    registry = TenantRegistry.registry_name(tenant_id)

    case Horde.Registry.lookup(registry, {:stateful_alert_engine, tenant_id}) do
      [{pid, _}] -> pid
      _ -> nil
    end
  end

  defp via_tuple(tenant_id) do
    registry = TenantRegistry.registry_name(tenant_id)
    {:via, Horde.Registry, {registry, {:stateful_alert_engine, tenant_id}}}
  end

  defp load_rules_if_needed(%{rules_loaded_at: nil} = state) do
    load_rules(state)
  end

  defp load_rules_if_needed(state) do
    now = System.monotonic_time(:millisecond)

    if now - state.rules_loaded_at > @rules_cache_ms do
      load_rules(state)
    else
      {state, state.rules}
    end
  end

  defp load_rules(state) do
    rules =
      StatefulAlertRule
      |> Ash.Query.for_read(:active, %{}, tenant: state.schema)
      |> Ash.read(authorize?: false)
      |> unwrap_page()

    updated = %{state | rules: rules, rules_loaded_at: System.monotonic_time(:millisecond)}
    {updated, rules}
  rescue
    error ->
      Logger.warning("Failed to load stateful alert rules: #{inspect(error)}")
      {state, []}
  end

  defp unwrap_page({:ok, %Ash.Page.Keyset{results: results}}), do: results
  defp unwrap_page({:ok, results}) when is_list(results), do: results
  defp unwrap_page(_), do: []

  defp load_state_snapshots(state) do
    StatefulAlertRuleState
    |> Ash.Query.for_read(:read, %{}, tenant: state.schema)
    |> Ash.read(authorize?: false)
    |> case do
      {:ok, %Ash.Page.Keyset{results: results}} -> results
      {:ok, results} when is_list(results) -> results
      _ -> []
    end
    |> Enum.each(fn snapshot ->
      key = {snapshot.rule_id, snapshot.group_key}
      :ets.insert(state.table, {key, normalize_snapshot(snapshot)})
    end)
  rescue
    error ->
      Logger.warning("Failed to load rule snapshots: #{inspect(error)}")
  end

  defp normalize_snapshot(snapshot) do
    %{
      rule_id: snapshot.rule_id,
      tenant_id: snapshot.tenant_id,
      group_key: snapshot.group_key,
      group_values: snapshot.group_values || %{},
      window_seconds: snapshot.window_seconds,
      bucket_seconds: snapshot.bucket_seconds,
      current_bucket_start: to_bucket_start(snapshot.current_bucket_start),
      bucket_counts: normalize_bucket_counts(snapshot.bucket_counts || %{}),
      last_seen_at: snapshot.last_seen_at,
      last_fired_at: snapshot.last_fired_at,
      last_notification_at: snapshot.last_notification_at,
      cooldown_until: snapshot.cooldown_until,
      alert_id: snapshot.alert_id
    }
  end

  defp process_log(rule, log, state), do: process_record(rule, log, state)
  defp process_event(rule, event, state), do: process_record(rule, event, state)

  defp process_record(rule, record, state) do
    tenant_id = record[:tenant_id] || record["tenant_id"]

    if is_nil(tenant_id) do
      Logger.warning("Skipping stateful alert evaluation; record missing tenant_id")
      :ok
    else
      case build_group(rule.group_by, record) do
        {:ok, group_key, group_values} ->
          key = {rule.id, group_key}
          snapshot = lookup_snapshot(state.table, key, rule, group_key, group_values, record)
          updated = update_snapshot(snapshot, rule, record)
          flushed = maybe_flush_snapshot(updated, rule, state)
          :ets.insert(state.table, {key, flushed})

        :error ->
          :ok
      end
    end
  end

  defp lookup_snapshot(table, key, rule, group_key, group_values, record) do
    case :ets.lookup(table, key) do
      [{^key, snapshot}] ->
        snapshot

      _ ->
        %{
          rule_id: rule.id,
          tenant_id: record[:tenant_id] || record["tenant_id"],
          group_key: group_key,
          group_values: group_values,
          window_seconds: rule.window_seconds,
          bucket_seconds: rule.bucket_seconds,
          current_bucket_start: record_bucket_start(record, rule.bucket_seconds),
          bucket_counts: %{},
          last_seen_at: nil,
          last_fired_at: nil,
          last_notification_at: nil,
          cooldown_until: nil,
          alert_id: nil
        }
    end
  end

  defp update_snapshot(snapshot, rule, record) do
    now = record_timestamp(record)
    bucket_start = record_bucket_start(record, rule.bucket_seconds)

    {bucket_counts, current_bucket_start, bucket_changed} =
      advance_bucket(snapshot.bucket_counts, snapshot.current_bucket_start, bucket_start, rule)

    bucket_counts = Map.update(bucket_counts, bucket_start, 1, &(&1 + 1))
    bucket_counts = prune_buckets(bucket_counts, current_bucket_start, rule.window_seconds, rule.bucket_seconds)
    window_count = window_count(bucket_counts)

    snapshot =
      snapshot
      |> Map.put(:bucket_counts, bucket_counts)
      |> Map.put(:current_bucket_start, current_bucket_start)
      |> Map.put(:last_seen_at, now)
      |> Map.put(:bucket_changed, bucket_changed)
      |> Map.put(:window_count, window_count)
      |> Map.put_new(:tenant_id, record[:tenant_id] || record["tenant_id"])
      |> Map.put_new(:flush_required, false)

    handle_threshold(snapshot, rule, record, now)
  end

  defp handle_threshold(snapshot, rule, record, now) do
    threshold = rule.threshold
    window_count = snapshot.window_count || 0

    cond do
      window_count >= threshold ->
        handle_firing(snapshot, rule, record, now)

      is_binary(snapshot.alert_id) ->
        handle_recovery(snapshot, rule, record, now)

      true ->
        snapshot
    end
  end

  defp handle_firing(snapshot, rule, record, now) do
    cooldown_until = snapshot.cooldown_until

    cond do
      is_binary(snapshot.alert_id) ->
        maybe_renotify(snapshot, rule, now)

      cooldown_until && DateTime.compare(now, cooldown_until) == :lt ->
        record_history(rule, snapshot, :cooldown, now, nil, %{"window_count" => snapshot.window_count})
        snapshot

      true ->
        case create_event_and_alert(rule, snapshot, record, now) do
          {:ok, alert_id} ->
            snapshot
            |> Map.put(:alert_id, alert_id)
            |> Map.put(:last_fired_at, now)
            |> Map.put(:last_notification_at, now)
            |> Map.put(:cooldown_until, add_seconds(now, rule.cooldown_seconds))
            |> Map.put(:flush_required, true)

          {:error, reason} ->
            Logger.warning("Failed to create alert for rule #{rule.id}: #{inspect(reason)}")
            snapshot
        end
    end
  end

  defp handle_recovery(snapshot, rule, _record, now) do
    resolve_alert(snapshot.alert_id, rule, snapshot, now)

    snapshot
    |> Map.put(:alert_id, nil)
    |> Map.put(:last_notification_at, nil)
    |> Map.put(:flush_required, true)
  end

  defp maybe_renotify(snapshot, rule, now) do
    renotify_seconds = rule.renotify_seconds || 0
    last_notification = snapshot.last_notification_at || snapshot.last_fired_at

    if renotify_seconds > 0 and last_notification &&
         DateTime.diff(now, last_notification, :second) >= renotify_seconds do
      case send_renotify(snapshot.alert_id, rule, snapshot, now) do
        :ok ->
          record_history(rule, snapshot, :renotify, now, snapshot.alert_id, %{})

          snapshot
          |> Map.put(:last_notification_at, now)
          |> Map.put(:flush_required, true)

        {:error, reason} ->
          Logger.warning("Failed to renotify alert #{snapshot.alert_id}: #{inspect(reason)}")
          snapshot
      end
    else
      snapshot
    end
  end

  defp maybe_flush_snapshot(snapshot, rule, state) do
    if snapshot.bucket_changed || snapshot.flush_required do
      persist_snapshot(snapshot, rule, state)

      snapshot
      |> Map.put(:bucket_changed, false)
      |> Map.put(:flush_required, false)
    else
      snapshot
    end
  end

  defp persist_snapshot(snapshot, rule, state) do
    params = %{
      rule_id: rule.id,
      group_key: snapshot.group_key,
      group_values: snapshot.group_values,
      window_seconds: rule.window_seconds,
      bucket_seconds: rule.bucket_seconds,
      current_bucket_start: from_bucket_start(snapshot.current_bucket_start),
      bucket_counts: stringify_bucket_counts(snapshot.bucket_counts),
      last_seen_at: snapshot.last_seen_at,
      last_fired_at: snapshot.last_fired_at,
      last_notification_at: snapshot.last_notification_at,
      cooldown_until: snapshot.cooldown_until,
      alert_id: snapshot.alert_id,
      tenant_id: state.tenant_id
    }

    StatefulAlertRuleState
    |> Ash.Changeset.for_create(:upsert, params, tenant: state.schema, actor: system_actor(state.tenant_id))
    |> Ash.create(authorize?: false)
    |> case do
      {:ok, _} -> :ok
      {:error, reason} ->
        Logger.warning("Failed to persist rule snapshot: #{inspect(reason)}")
        :error
    end
  end

  defp create_event_and_alert(rule, snapshot, record, now) do
    tenant_id = record[:tenant_id] || record["tenant_id"] || snapshot.tenant_id

    if is_nil(tenant_id) do
      {:error, :missing_tenant_id}
    else
      schema = tenant_schema(rule, tenant_id)
      event = build_event(rule, snapshot, record, now, tenant_id)

      with {:ok, ocsf_event} <- record_event(event, schema, tenant_id) do
        case AlertGenerator.from_event(ocsf_event, tenant: schema, alert: rule.alert) do
          {:ok, %Alert{} = alert} ->
            record_history(rule, snapshot, :fired, now, alert.id, %{"event_id" => ocsf_event.id})
            {:ok, alert.id}

          {:ok, :skipped} ->
            {:error, :alert_disabled}

          {:error, reason} ->
            {:error, reason}
        end
      end
    end
  end

  defp record_event(attrs, schema, tenant_id) do
    OcsfEvent
    |> Ash.Changeset.for_create(:record, attrs, tenant: schema)
    |> Ash.Changeset.force_change_attribute(:tenant_id, tenant_id)
    |> Ash.create(authorize?: false)
  end

  defp resolve_alert(alert_id, rule, snapshot, now) when is_binary(alert_id) do
    tenant_id = snapshot.tenant_id
    schema = tenant_schema(rule, tenant_id)

    if is_nil(schema) do
      :ok
    else
      case Alert.get_by_id(alert_id, tenant: schema, authorize?: false) do
        {:ok, alert} ->
          case alert
               |> Ash.Changeset.for_update(:resolve, %{resolved_by: "system"},
                 tenant: schema,
                 actor: system_actor(tenant_id)
               )
               |> Ash.update(authorize?: false) do
            {:ok, _} ->
              record_history(rule, snapshot, :recovered, now, alert_id, %{})
              :ok

            {:error, reason} ->
              Logger.warning("Failed to resolve alert #{alert_id}: #{inspect(reason)}")
              :error
          end

        {:error, _} ->
          :ok
      end
    end
  end

  defp resolve_alert(_alert_id, _rule, _snapshot, _now), do: :ok

  defp send_renotify(alert_id, _rule, snapshot, now) when is_binary(alert_id) do
    tenant_id = snapshot.tenant_id
    schema = tenant_schema(nil, tenant_id)

    if is_nil(schema) do
      {:error, :missing_tenant_schema}
    else
      case Alert.get_by_id(alert_id, tenant: schema, authorize?: false) do
        {:ok, alert} ->
          alert_key = %WebhookNotifier.Alert{
            level: severity_to_level(alert.severity),
            title: alert.title,
            message: alert.description,
            timestamp: DateTime.to_iso8601(now),
            gateway_id: "core",
            service_name: nil,
            details: alert.metadata || %{}
          }

          _ = WebhookNotifier.send_alert(alert_key)

          alert
          |> Ash.Changeset.for_update(:record_notification, %{},
            tenant: schema,
            actor: system_actor(tenant_id)
          )
          |> Ash.update(authorize?: false)

          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp send_renotify(_alert_id, _rule, _snapshot, _now), do: {:error, :missing_alert_id}

  defp severity_to_level(:emergency), do: :error
  defp severity_to_level(:critical), do: :error
  defp severity_to_level(:warning), do: :warning
  defp severity_to_level(:info), do: :info
  defp severity_to_level(_), do: :warning

  defp build_event(rule, snapshot, record, now, tenant_id) do
    activity_id = OCSF.activity_log_create()
    class_uid = OCSF.class_event_log_activity()
    category_uid = OCSF.category_system_activity()
    severity_id = severity_id(rule.alert)
    message_override = rule.event["message"] || rule.event[:message]

    message =
      message_override ||
        "Stateful rule #{rule.name} triggered for #{snapshot.group_key} (#{snapshot.window_count}/#{rule.threshold} in #{rule.window_seconds}s)"

    source = source_record_details(record)

    %{
      time: now,
      class_uid: class_uid,
      category_uid: category_uid,
      type_uid: OCSF.type_uid(class_uid, activity_id),
      activity_id: activity_id,
      activity_name: OCSF.log_activity_name(activity_id),
      severity_id: severity_id,
      severity: OCSF.severity_name(severity_id),
      message: message,
      status_id: OCSF.status_failure(),
      status: OCSF.status_name(OCSF.status_failure()),
      metadata:
        OCSF.build_metadata(
          version: "1.7.0",
          product_name: "ServiceRadar Core",
          correlation_uid: "stateful_rule:#{rule.id}:#{snapshot.group_key}"
        )
        |> Map.put(:serviceradar, %{
          stateful_rule: true,
          rule_id: rule.id,
          group_key: snapshot.group_key
        }),
      actor: OCSF.build_actor(app_name: "serviceradar.core", process: "stateful_alert_engine"),
      log_name: rule.event["log_name"] || rule.event[:log_name] || "alert.rule.threshold",
      log_provider: "serviceradar.core",
      log_level: log_level_for_severity(severity_id),
      unmapped:
        %{
          "rule_id" => to_string(rule.id),
          "rule_name" => rule.name,
          "group_key" => snapshot.group_key,
          "group_values" => snapshot.group_values,
          "threshold" => rule.threshold,
          "window_seconds" => rule.window_seconds,
          "bucket_seconds" => rule.bucket_seconds,
          "window_count" => snapshot.window_count,
          "cooldown_seconds" => rule.cooldown_seconds,
          "renotify_seconds" => rule.renotify_seconds
        }
        |> Map.merge(source),
      tenant_id: tenant_id
    }
  end

  defp severity_id(alert_overrides) do
    overrides = alert_overrides || %{}

    severity =
      overrides["severity"] ||
        overrides[:severity] ||
        :warning

    case severity do
      :emergency -> OCSF.severity_fatal()
      :critical -> OCSF.severity_critical()
      :warning -> OCSF.severity_medium()
      :info -> OCSF.severity_informational()
      _ -> OCSF.severity_medium()
    end
  end

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

  defp record_history(rule, snapshot, event_type, now, alert_id, details) do
    schema = tenant_schema(rule, snapshot.tenant_id)

    if is_nil(schema) do
      :error
    else
      params = %{
        event_time: now,
        rule_id: rule.id,
        group_key: snapshot.group_key,
        event_type: event_type,
        alert_id: alert_id,
        details: details,
        tenant_id: snapshot.tenant_id
      }

      StatefulAlertRuleHistory
      |> Ash.Changeset.for_create(:record, params, tenant: schema, actor: system_actor(snapshot.tenant_id))
      |> Ash.create(authorize?: false)
      |> case do
        {:ok, _} -> :ok
        {:error, reason} ->
          Logger.warning("Failed to record rule history: #{inspect(reason)}")
          :error
      end
    end
  end

  defp rule_matches_log?(log, rule) do
    match = rule.match || %{}

    if match["always"] == true do
      true
    else
      subject = ingest_subject(log)
      attributes = Map.get(log, :attributes) || %{}
      resource_attributes = Map.get(log, :resource_attributes) || %{}

      match_subject_prefix(subject, match) and
        match_service_name_value(Map.get(log, :service_name), match) and
        match_severity_values(Map.get(log, :severity_number), Map.get(log, :severity_text), match) and
        match_body_value(Map.get(log, :body), match) and
        match_map(attributes, match["attribute_equals"]) and
        match_map(resource_attributes, match["resource_attribute_equals"])
    end
  end

  defp rule_matches_event?(event, rule) do
    match = rule.match || %{}

    if match["always"] == true do
      true
    else
      log_name = Map.get(event, :log_name) || Map.get(event, "log_name")
      log_provider = Map.get(event, :log_provider) || Map.get(event, "log_provider")
      severity_id = Map.get(event, :severity_id) || Map.get(event, "severity_id")
      severity = Map.get(event, :severity) || Map.get(event, "severity")
      message = Map.get(event, :message) || Map.get(event, "message")
      {attributes, resource_attributes} = event_match_sources(event)

      match_subject_prefix(log_name, match) and
        match_service_name_value(log_provider, match) and
        match_severity_values(severity_id, severity, match) and
        match_body_value(message, match) and
        match_map(attributes, match["attribute_equals"]) and
        match_map(resource_attributes, match["resource_attribute_equals"])
    end
  end

  defp match_subject_prefix(_subject, match) when map_size(match) == 0, do: false

  defp match_subject_prefix(subject, match) do
    case match["subject_prefix"] do
      nil -> true
      prefix when is_binary(prefix) and is_binary(subject) -> String.starts_with?(subject, prefix)
      _ -> false
    end
  end

  defp match_service_name_value(value, match) do
    case match["service_name"] do
      nil -> true
      expected -> match_value(value, expected)
    end
  end

  defp match_severity_values(severity_number, severity_text, match) do
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

  defp match_body_value(body, match) do
    case match["body_contains"] do
      nil -> true
      needle when is_binary(needle) ->
        body = body || ""
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
    attributes = Map.get(log, :attributes, %{})
    get_nested_value(attributes, "serviceradar.ingest.subject")
  end

  defp build_group(nil, _log), do: {:ok, "global", %{}}
  defp build_group([], _log), do: {:ok, "global", %{}}

  defp build_group(keys, record) when is_list(keys) do
    attributes = Map.get(record, :attributes) || %{}
    resource_attributes = Map.get(record, :resource_attributes) || %{}
    unmapped = Map.get(record, :unmapped) || %{}
    metadata = Map.get(record, :metadata) || %{}
    log_attributes = event_log_attributes(record)
    log_resource_attributes = event_log_resource_attributes(record)

    values =
      Enum.reduce(keys, %{}, fn key, acc ->
        value =
          get_nested_value(attributes, key) ||
            get_nested_value(resource_attributes, key) ||
            get_nested_value(log_attributes, key) ||
            get_nested_value(log_resource_attributes, key) ||
            get_nested_value(unmapped, key) ||
            get_nested_value(metadata, key) ||
            record_field_value(record, key)

        if is_nil(value), do: acc, else: Map.put(acc, key, to_string(value))
      end)

    if map_size(values) == length(keys) do
      group_key =
        keys
        |> Enum.map(fn key -> "#{key}=#{Map.get(values, key)}" end)
        |> Enum.join("|")

      {:ok, group_key, values}
    else
      :error
    end
  end

  defp record_timestamp(record) do
    case Map.get(record, :time) || Map.get(record, "time") do
      %DateTime{} = dt ->
        dt

      _ ->
        case Map.get(record, :timestamp) || Map.get(record, "timestamp") do
          %DateTime{} = dt -> dt
          _ -> DateTime.utc_now()
        end
    end
  end

  defp record_field_value(record, key) when is_binary(key) do
    case key do
      "service_name" -> Map.get(record, :service_name) || Map.get(record, :log_provider)
      "severity_text" -> Map.get(record, :severity_text) || Map.get(record, :severity)
      "severity_number" -> Map.get(record, :severity_number) || Map.get(record, :severity_id)
      "body" -> Map.get(record, :body) || Map.get(record, :message)
      "log_name" -> Map.get(record, :log_name)
      "log_provider" -> Map.get(record, :log_provider)
      _ -> nil
    end
  end

  defp record_bucket_start(record, bucket_seconds) do
    record
    |> record_timestamp()
    |> to_bucket_start(bucket_seconds)
  end

  defp to_bucket_start(%DateTime{} = dt, bucket_seconds) when is_integer(bucket_seconds) do
    unix = DateTime.to_unix(dt, :second)
    unix - rem(unix, bucket_seconds)
  end

  defp to_bucket_start(%DateTime{} = dt), do: DateTime.to_unix(dt, :second)
  defp to_bucket_start(nil), do: nil
  defp to_bucket_start(value) when is_integer(value), do: value

  defp from_bucket_start(unix) when is_integer(unix) do
    DateTime.from_unix!(unix, :second)
  end

  defp advance_bucket(bucket_counts, current_bucket_start, bucket_start, _rule) do
    current = current_bucket_start || bucket_start

    if bucket_start > current do
      {bucket_counts, bucket_start, true}
    else
      {bucket_counts, current, false}
    end
  end

  defp prune_buckets(bucket_counts, current_bucket_start, window_seconds, bucket_seconds) do
    min_bucket = current_bucket_start - (window_seconds - bucket_seconds)

    bucket_counts
    |> Enum.filter(fn {bucket, _} -> bucket >= min_bucket end)
    |> Map.new()
  end

  defp window_count(bucket_counts) do
    bucket_counts
    |> Map.values()
    |> Enum.sum()
  end

  defp normalize_bucket_counts(bucket_counts) when is_map(bucket_counts) do
    bucket_counts
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      case Integer.parse(to_string(key)) do
        {bucket, _} -> Map.put(acc, bucket, value)
        :error -> acc
      end
    end)
  end

  defp stringify_bucket_counts(bucket_counts) do
    bucket_counts
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      Map.put(acc, to_string(key), value)
    end)
  end

  defp tenant_schema(_rule, nil), do: nil

  defp tenant_schema(_rule, tenant_id) do
    ServiceRadar.Cluster.TenantSchemas.schema_for_tenant(tenant_id)
  end

  defp add_seconds(%DateTime{} = dt, seconds) when is_integer(seconds) do
    DateTime.add(dt, seconds, :second)
  end

  defp system_actor(tenant_id) do
    %{id: "system", role: :admin, tenant_id: tenant_id}
  end

  defp skip_engine_event?(event) do
    metadata = Map.get(event, :metadata) || Map.get(event, "metadata") || %{}
    serviceradar = Map.get(metadata, :serviceradar) || Map.get(metadata, "serviceradar") || %{}
    stateful = Map.get(serviceradar, :stateful_rule) || Map.get(serviceradar, "stateful_rule")

    if stateful == true do
      true
    else
      log_name = Map.get(event, :log_name) || Map.get(event, "log_name")
      log_provider = Map.get(event, :log_provider) || Map.get(event, "log_provider")
      log_name == "alert.rule.threshold" and log_provider == "serviceradar.core"
    end
  end

  defp source_record_details(record) do
    has_time = Map.has_key?(record, :time) || Map.has_key?(record, "time")

    if has_time do
      %{
        "source_signal" => "event",
        "source_event_id" => Map.get(record, :id) || Map.get(record, "id"),
        "source_event_time" => Map.get(record, :time) || Map.get(record, "time"),
        "source_log_name" => Map.get(record, :log_name) || Map.get(record, "log_name"),
        "source_log_provider" => Map.get(record, :log_provider) || Map.get(record, "log_provider")
      }
    else
      %{
        "source_signal" => "log",
        "source_log_id" => Map.get(record, :id) || Map.get(record, "id"),
        "source_log_time" => Map.get(record, :timestamp) || Map.get(record, "timestamp"),
        "source_service" => Map.get(record, :service_name) || Map.get(record, "service_name")
      }
    end
  end

  defp event_match_sources(event) do
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

  defp event_log_attributes(event) do
    unmapped = event_unmapped(event)
    Map.get(unmapped, "log_attributes") || Map.get(unmapped, :log_attributes) || %{}
  end

  defp event_log_resource_attributes(event) do
    unmapped = event_unmapped(event)
    Map.get(unmapped, "log_resource_attributes") || Map.get(unmapped, :log_resource_attributes) || %{}
  end

  defp event_unmapped(event) do
    Map.get(event, :unmapped) || Map.get(event, "unmapped") || %{}
  end
end
