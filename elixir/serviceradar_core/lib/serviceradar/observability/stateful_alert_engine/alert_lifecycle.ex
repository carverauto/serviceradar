defmodule ServiceRadar.Observability.StatefulAlertEngine.AlertLifecycle do
  @moduledoc """
  The alert/incident lifecycle and durable persistence for a fired rule: building
  and recording the OCSF event, generating the alert, resolving it on recovery,
  re-notifying, syncing incident metadata, recording rule history, and upserting
  the rule-state snapshot.

  All Ash writes run as the `:alert_engine` system actor; the DB connection's
  search_path determines the schema.

  ## Notification

  This module is the single choke point where an incident fires, resolves, or is
  re-notified, which design D8 makes the ONLY path allowed to originate a new
  incident notification: it is where incident identity, dedup state, and the
  alert row are already consistent. Each of the three emits one
  `ServiceRadar.Notifications.RoutingWorker` job - `:fire`, `:resolve`,
  `:renotify` - and decides nothing else. Matching, deduplication, escalation,
  suppression, rendering, and the retry rule are
  `ServiceRadar.Notifications.Dispatcher`'s, and through it the pure cores'.

  Two properties are load bearing here, because this module runs inside a
  Horde-sharded, latency-sensitive engine.

  1. **The enqueue happens after the write returns, never inside it.** Each Ash
     call opens and closes its own transaction, so calling `enqueue_routing/2`
     on the result keeps the job insert off the incident-recording transaction.
  2. **A notification failure never breaks incident recording.** The enqueue is
     logged and swallowed. An incident that is recorded but not routed is
     recoverable - `Alert.:needs_notification` still finds an alert that has
     never notified. An incident that was never recorded is not.
  """

  import ServiceRadar.Observability.StatefulAlertEngine.Bucketing
  import ServiceRadar.Observability.StatefulAlertEngine.Diagnostics
  import ServiceRadar.Observability.StatefulAlertEngine.Record
  import ServiceRadar.Observability.StatefulAlertEngine.Severity

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.EventWriter.OCSF
  alias ServiceRadar.Monitoring.Alert
  alias ServiceRadar.Monitoring.AlertGenerator
  alias ServiceRadar.Monitoring.OcsfEvent
  alias ServiceRadar.Notifications.RoutingWorker
  alias ServiceRadar.Observability.StatefulAlertRuleHistory
  alias ServiceRadar.Observability.StatefulAlertRuleState

  require Logger

  def create_event_and_alert(rule, snapshot, record, now) do
    event = build_event(rule, snapshot, record, now)
    synthetic_liveness_check? = synthetic_liveness_check?(record)
    # DB connection's search_path determines the schema
    actor = SystemActor.system(:alert_engine)

    with {:ok, ocsf_event} <- record_event(event, actor) do
      case AlertGenerator.from_event(ocsf_event,
             actor: actor,
             alert: alert_config(rule, record)
           ) do
        {:ok, %Alert{} = alert} ->
          if !synthetic_liveness_check? do
            record_history(rule, snapshot, :fired, now, alert.id, %{"event_id" => ocsf_event.id})

            # Inside the guard on purpose. A synthetic liveness probe is an
            # internal check on the anomaly pipeline, not an incident anyone is
            # on call for, and routing it would page for ServiceRadar watching
            # itself.
            enqueue_routing(alert.id, :fire)
          end

          {:ok, alert.id}

        {:ok, :skipped} ->
          {:error, :alert_disabled}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp record_event(attrs, actor) do
    # DB connection's search_path determines the schema
    OcsfEvent
    |> Ash.Changeset.for_create(:record, attrs, actor: actor)
    |> Ash.create()
  end

  def resolve_alert(alert_id, rule, snapshot, now) when is_binary(alert_id) do
    # DB connection's search_path determines the schema
    actor = SystemActor.system(:alert_engine)

    case Alert.get_by_id(alert_id, actor: actor) do
      {:ok, %Alert{status: status}} when status in [:resolved, :suppressed] ->
        # Already terminal (resolved out-of-band via REST/sweep/duplicate clear).
        # Idempotent no-op; do not re-fire :resolve (NoMatchingTransition) or
        # re-record :recovered history (duplicate-row spam on every retry).
        :ok

      {:ok, alert} ->
        alert
        |> Ash.Changeset.for_update(:resolve, %{resolved_by: "system"}, actor: actor)
        |> Ash.update()
        |> case do
          {:ok, _} ->
            if !synthetic_liveness_snapshot?(snapshot) do
              record_history(rule, snapshot, :recovered, now, alert_id, %{})

              # The resolution is routed, not broadcast: design D5 sends it to
              # the channels that received the firing notification, correlated
              # through `external_correlation_id`, unless the policy disables
              # resolution notices. That decision is `Dispatcher.route/3`'s.
              enqueue_routing(alert_id, :resolve)
            end

            :ok

          {:error, reason} ->
            Logger.warning("Failed to resolve alert #{alert_id}: #{inspect(reason)}")
            :error
        end

      {:error, _} ->
        :ok
    end
  end

  def resolve_alert(_alert_id, _rule, _snapshot, _now), do: :ok

  def send_renotify(alert_id, _rule, _snapshot, _now) when is_binary(alert_id) do
    # DB connection's search_path determines the schema
    actor = SystemActor.system(:alert_engine)

    case Alert.get_by_id(alert_id, actor: actor) do
      {:ok, alert} ->
        enqueue_routing(alert.id, :renotify)

        # `:record_notification` is bookkeeping only and deliberately does not
        # enqueue: the routing request above is this repeat's one emission, and
        # the counter it bumps is what the renotify cadence reads.
        alert
        |> Ash.Changeset.for_update(:record_notification, %{}, actor: actor)
        |> Ash.update()

        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  def send_renotify(_alert_id, _rule, _snapshot, _now), do: {:error, :missing_alert_id}

  # Never raises and never returns an error: see the "Notification" section of
  # the moduledoc. A routing request that could not be enqueued is a logged
  # notification failure, not a reason to abandon the incident record that the
  # caller has already written.
  defp enqueue_routing(alert_id, lifecycle_reason) do
    case RoutingWorker.enqueue(alert_id, lifecycle_reason) do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Failed to enqueue #{lifecycle_reason} notification routing for alert " <>
            "#{alert_id}: #{inspect(reason)}"
        )

        :ok
    end
  end

  def sync_active_incident(snapshot, rule, now, opts \\ []) do
    if is_binary(snapshot.alert_id) do
      reset? = Keyword.get(opts, :reset?, false)
      actor = SystemActor.system(:alert_engine)

      case Alert.get_by_id(snapshot.alert_id, actor: actor) do
        {:ok, alert} ->
          metadata = merge_incident_metadata(alert.metadata || %{}, snapshot, rule, now, reset?)

          case alert
               |> Ash.Changeset.for_update(:update_metadata, %{metadata: metadata}, actor: actor)
               |> Ash.update() do
            {:ok, _updated} ->
              snapshot

            {:error, reason} ->
              Logger.warning(
                "Failed to update incident metadata for alert #{snapshot.alert_id}: #{inspect(reason)}"
              )

              snapshot
          end

        {:error, reason} ->
          Logger.warning(
            "Failed to load alert #{snapshot.alert_id} for incident metadata sync: #{inspect(reason)}"
          )

          snapshot
      end
    else
      snapshot
    end
  end

  defp merge_incident_metadata(metadata, snapshot, rule, now, reset?) do
    occurrence_count =
      if reset? do
        1
      else
        metadata
        |> Map.get("incident_occurrence_count", 1)
        |> normalize_incident_count()
        |> Kernel.+(1)
      end

    first_seen_at =
      if reset? do
        DateTime.to_iso8601(now)
      else
        Map.get(metadata, "incident_first_seen_at") || DateTime.to_iso8601(now)
      end

    metadata
    |> Map.put("incident_rule_id", to_string(rule.id))
    |> Map.put("incident_rule_name", rule.name)
    |> Map.put("incident_group_key", snapshot.group_key)
    |> Map.put("incident_group_values", snapshot.group_values || %{})
    |> Map.put("incident_occurrence_count", occurrence_count)
    |> Map.put("incident_first_seen_at", first_seen_at)
    |> Map.put("incident_last_seen_at", DateTime.to_iso8601(now))
    |> Map.put("incident_window_count", snapshot.window_count || 0)
    |> Map.put("incident_diagnostics", diagnostic_summary(rule, snapshot, now))
  end

  defp normalize_incident_count(value) when is_integer(value) and value > 0, do: value

  defp normalize_incident_count(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, _} when parsed > 0 -> parsed
      _ -> 1
    end
  end

  defp normalize_incident_count(_value), do: 1

  defp build_event(rule, snapshot, record, now) do
    activity_id = OCSF.activity_log_create()
    class_uid = OCSF.class_event_log_activity()
    category_uid = OCSF.category_system_activity()
    severity_id = severity_id(rule.alert, record)
    message_override = rule.event["message"] || rule.event[:message]

    message =
      message_override ||
        "Stateful rule #{rule.name} triggered for #{snapshot.group_key} (#{snapshot.window_count}/#{rule.threshold} in #{rule.window_seconds}s)"

    source = source_record_details(record)
    diagnostics = diagnostic_summary(rule, snapshot, now, source)

    serviceradar_metadata =
      maybe_mark_synthetic_liveness(
        %{
          stateful_rule: true,
          rule_id: to_string(rule.id),
          group_key: snapshot.group_key,
          diagnostics: diagnostics
        },
        record
      )

    Map.put(
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
          [
            product_name: "ServiceRadar Core",
            correlation_uid: "stateful_rule:#{rule.id}:#{snapshot.group_key}"
          ]
          |> OCSF.build_metadata()
          |> Map.put(:serviceradar, serviceradar_metadata),
        actor: OCSF.build_actor(app_name: "serviceradar.core", process: "stateful_alert_engine"),
        log_name: rule.event["log_name"] || rule.event[:log_name] || "alert.rule.threshold",
        log_provider: "serviceradar.core",
        log_level: log_level_for_severity(severity_id)
      },
      :unmapped,
      build_unmapped(rule, snapshot, source, diagnostics)
    )
  end

  defp alert_config(rule, record) do
    alert = rule.alert || %{}

    if synthetic_liveness_check?(record) do
      metadata =
        alert
        |> then(&(Map.get(&1, "metadata") || Map.get(&1, :metadata)))
        |> case do
          %{} = metadata -> metadata
          _ -> %{}
        end
        |> Map.put("synthetic_liveness_check", true)
        |> Map.put("synthetic_liveness_series_key", synthetic_liveness_series_key(record))

      Map.put(alert, "metadata", metadata)
    else
      alert
    end
  end

  defp maybe_mark_synthetic_liveness(metadata, record) do
    if synthetic_liveness_check?(record) do
      metadata
      |> Map.put(:synthetic_liveness_check, true)
      |> Map.put(:synthetic_liveness_series_key, synthetic_liveness_series_key(record))
    else
      metadata
    end
  end

  defp synthetic_liveness_series_key(record) do
    record
    |> event_unmapped()
    |> then(&(Map.get(&1, "anomaly") || Map.get(&1, :anomaly)))
    |> case do
      %{} = anomaly -> Map.get(anomaly, "series_key") || Map.get(anomaly, :series_key)
      _ -> nil
    end
  end

  defp synthetic_liveness_snapshot?(snapshot) do
    get_in(snapshot, [:diagnostics, "latest_source", "source_synthetic_liveness_check"]) == true
  end

  defp build_unmapped(rule, snapshot, source, diagnostics) do
    Map.merge(
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
        "renotify_seconds" => rule.renotify_seconds,
        "diagnostics" => diagnostics
      },
      source
    )
  end

  def record_history(rule, snapshot, event_type, now, alert_id, details) do
    # DB connection's search_path determines the schema
    actor = SystemActor.system(:alert_engine)

    params = %{
      event_time: now,
      rule_id: rule.id,
      group_key: snapshot.group_key,
      event_type: event_type,
      alert_id: alert_id,
      details: details
    }

    StatefulAlertRuleHistory
    |> Ash.Changeset.for_create(:record, params, actor: actor)
    |> Ash.create()
    |> case do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to record rule history: #{inspect(reason)}")
        :error
    end
  end

  def persist_snapshot(snapshot, rule, state) do
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
      alert_id: snapshot.alert_id
    }

    StatefulAlertRuleState
    |> Ash.Changeset.for_create(:upsert, params, state.ash_opts)
    |> Ash.create()
    |> case do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to persist rule snapshot: #{inspect(reason)}")
        :error
    end
  end
end
