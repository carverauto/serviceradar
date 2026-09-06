defmodule ServiceRadar.Observability.StatefulAlertEngine.StateMachine do
  @moduledoc """
  The per-rule snapshot state machine: dispatching each log/event/metric record
  to the rules a shard owns, advancing the bucketed window snapshot in ETS,
  firing/rolling-over/recovering alerts at the threshold, re-notifying, flushing
  snapshots to Postgres, and the stale-anomaly auto-resolve sweep.

  Snapshots live in the owning shard's private ETS table (`state.table`); this
  module mutates that table and delegates all DB writes to
  `ServiceRadar.Observability.StatefulAlertEngine.AlertLifecycle`.
  """

  import ServiceRadar.Observability.StatefulAlertEngine.AlertLifecycle
  import ServiceRadar.Observability.StatefulAlertEngine.Bucketing
  import ServiceRadar.Observability.StatefulAlertEngine.Diagnostics
  import ServiceRadar.Observability.StatefulAlertEngine.EdgeAnomalyDisposition
  import ServiceRadar.Observability.StatefulAlertEngine.MetricCondition
  import ServiceRadar.Observability.StatefulAlertEngine.Record
  import ServiceRadar.Observability.StatefulAlertEngine.RuleMatcher

  require Logger

  def process_log_rules(log, rules, state) do
    process_rules(rules, &maybe_process_log_rule(log, &1, state))
  end

  defp maybe_process_log_rule(log, %{signal: :log} = rule, state) do
    if rule_matches_log?(log, rule), do: process_log(rule, log, state), else: :ok
  end

  defp maybe_process_log_rule(_log, _rule, _state), do: :ok

  def process_event_rules(event, rules, state) do
    if skip_engine_event?(event) do
      :ok
    else
      process_rules(rules, &maybe_process_event_rule(event, &1, state))
    end
  end

  defp maybe_process_event_rule(event, %{signal: :event} = rule, state) do
    case seasonal_disposition_for_edge_anomaly(event, rule) do
      {:ok, :suppress, _attrs, _disposition} ->
        :ok

      {:ok, action, attrs, disposition} ->
        event
        |> tag_edge_anomaly_disposition(action, attrs, disposition)
        |> maybe_process_matched_event_rule(rule, state)

      :ignore ->
        maybe_process_matched_event_rule(event, rule, state)
    end
  end

  defp maybe_process_event_rule(_event, _rule, _state), do: :ok

  defp maybe_process_matched_event_rule(event, rule, state) do
    cond do
      rule_matches_event?(event, rule) ->
        process_event(rule, event, state)

      rule_recovers_event?(event, rule) ->
        recover_event(rule, event, state)

      true ->
        :ok
    end
  end

  def process_metric_rules(metric, rules, state) do
    process_rules(rules, &maybe_process_metric_rule(metric, &1, state))
  end

  defp maybe_process_metric_rule(metric, %{signal: :metric} = rule, state) do
    if rule_matches_metric?(metric, rule),
      do: process_metric(rule, tag_metric_violation(metric, rule), state),
      else: :ok
  end

  defp maybe_process_metric_rule(_metric, _rule, _state), do: :ok

  defp process_rules(rules, process) do
    Enum.reduce(rules, :ok, fn rule, result ->
      case process.(rule) do
        :ok -> result
        {:error, _} = error -> if result == :ok, do: error, else: result
      end
    end)
  end

  defp store_snapshot({:error, _} = error, _rule, _state, _key), do: error

  defp store_snapshot(snapshot, rule, state, key) do
    {result, flushed} = maybe_flush_snapshot(snapshot, rule, state)
    :ets.insert(state.table, {key, flushed})
    result
  end

  defp process_log(rule, log, state), do: process_record(rule, log, state)
  defp process_event(rule, event, state), do: process_record(rule, event, state)
  defp process_metric(rule, metric, state), do: process_record(rule, metric, state)

  defp process_record(rule, record, state) do
    case build_group(rule.group_by, record) do
      {:ok, group_key, group_values} ->
        key = {rule.id, group_key}
        snapshot = lookup_snapshot(state.table, key, rule, group_key, group_values, record)

        snapshot
        |> update_snapshot(rule, record, state)
        |> store_snapshot(rule, state, key)

      :error ->
        :ok
    end
  end

  def recover_event(rule, record, state) do
    case build_group(rule.group_by, record) do
      {:ok, group_key, group_values} ->
        key = {rule.id, group_key}

        case :ets.lookup(state.table, key) do
          [{^key, snapshot}] ->
            now = record_timestamp(record)

            snapshot =
              snapshot
              |> Map.put(:group_values, group_values)
              |> Map.put(:bucket_counts, %{})
              |> Map.put(:current_bucket_start, record_bucket_start(record, rule.bucket_seconds))
              |> Map.put(:window_count, 0)
              |> Map.put(:last_seen_at, now)
              |> Map.put(:cooldown_until, nil)
              |> Map.put(:diagnostics, update_diagnostics(snapshot.diagnostics, record, now))
              |> handle_recovery(rule, record, now, state)

            store_snapshot(snapshot, rule, state, key)

          _ ->
            :ok
        end

      :error ->
        :ok
    end
  end

  defp lookup_snapshot(table, key, rule, group_key, group_values, record) do
    case :ets.lookup(table, key) do
      [{^key, snapshot}] ->
        snapshot

      _ ->
        %{
          rule_id: rule.id,
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
          alert_id: nil,
          first_seen_at: record_timestamp(record),
          diagnostics: empty_diagnostics()
        }
    end
  end

  defp update_snapshot(snapshot, rule, record, state) do
    now = record_timestamp(record)
    bucket_start = record_bucket_start(record, rule.bucket_seconds)
    previous_last_seen_at = snapshot.last_seen_at

    {bucket_counts, current_bucket_start, bucket_changed} =
      advance_bucket(snapshot.bucket_counts, snapshot.current_bucket_start, bucket_start, rule)

    bucket_increment = record_bucket_increment(record)

    bucket_counts =
      if bucket_increment > 0 do
        Map.update(bucket_counts, bucket_start, bucket_increment, &(&1 + bucket_increment))
      else
        Map.put_new(bucket_counts, bucket_start, 0)
      end

    bucket_counts =
      prune_buckets(bucket_counts, current_bucket_start, rule.window_seconds, rule.bucket_seconds)

    window_count = window_count(bucket_counts)

    snapshot =
      snapshot
      |> Map.put(:bucket_counts, bucket_counts)
      |> Map.put(:current_bucket_start, current_bucket_start)
      |> Map.put(:last_seen_at, now)
      |> Map.put(:previous_last_seen_at, previous_last_seen_at)
      |> Map.put(:bucket_changed, bucket_changed)
      |> Map.put(:window_count, window_count)
      |> Map.put(:first_seen_at, snapshot.first_seen_at || now)
      |> Map.put(:diagnostics, update_diagnostics(snapshot.diagnostics, record, now))
      |> Map.put_new(:flush_required, false)

    handle_threshold(snapshot, rule, record, now, state)
  end

  defp handle_threshold(snapshot, rule, record, now, state) do
    threshold = rule.threshold
    window_count = snapshot.window_count || 0

    cond do
      window_count >= threshold ->
        handle_firing(snapshot, rule, record, now, state)

      is_binary(snapshot.alert_id) ->
        handle_recovery(snapshot, rule, record, now, state)

      true ->
        snapshot
    end
  end

  defp handle_firing(snapshot, rule, record, now, state) do
    cooldown_until = snapshot.cooldown_until

    cond do
      is_binary(snapshot.alert_id) and incident_rollover?(snapshot, rule, now) ->
        rollover_incident(snapshot, rule, record, now, state)

      is_binary(snapshot.alert_id) ->
        snapshot
        |> sync_active_incident(rule, now)
        |> maybe_renotify(rule, now)

      cooldown_until && DateTime.before?(now, cooldown_until) ->
        record_history(rule, snapshot, :cooldown, now, nil, %{
          "window_count" => snapshot.window_count
        })

        snapshot

      true ->
        case create_snapshot_alert(rule, snapshot, record, now, state) do
          {:ok, alert_id} ->
            snapshot
            |> Map.put(:alert_id, alert_id)
            |> Map.put(:last_fired_at, now)
            |> Map.put(:last_notification_at, now)
            |> Map.put(:cooldown_until, add_seconds(now, rule.cooldown_seconds))
            |> sync_active_incident(rule, now, reset?: true)
            |> Map.put(:flush_required, true)

          {:error, reason} ->
            Logger.warning("Failed to create alert for rule #{rule.id}: #{inspect(reason)}")
            {:error, reason}
        end
    end
  end

  defp incident_rollover?(snapshot, rule, now) do
    gap_seconds = rule.cooldown_seconds || 0
    previous_last_seen_at = snapshot.previous_last_seen_at

    is_integer(gap_seconds) and gap_seconds > 0 and
      match?(%DateTime{}, previous_last_seen_at) and
      DateTime.diff(now, previous_last_seen_at, :second) > gap_seconds
  end

  defp rollover_incident(snapshot, rule, record, now, state) do
    case resolve_snapshot_alert(snapshot, rule, now, state) do
      :ok ->
        refreshed_snapshot =
          snapshot
          |> Map.put(:alert_id, nil)
          |> Map.put(:last_notification_at, nil)
          |> Map.put(:cooldown_until, nil)
          |> Map.put(:first_seen_at, now)
          |> Map.put(:diagnostics, update_diagnostics(empty_diagnostics(), record, now))
          |> Map.put(:flush_required, true)

        handle_firing(refreshed_snapshot, rule, record, now, state)

      {:error, reason} ->
        Logger.warning(
          "Keeping alert #{snapshot.alert_id} open after rollover resolution failed: " <>
            inspect(reason)
        )

        {:error, reason}
    end
  end

  defp handle_recovery(snapshot, rule, _record, now, state) do
    case resolve_snapshot_alert(snapshot, rule, now, state) do
      :ok ->
        snapshot
        |> Map.put(:alert_id, nil)
        |> Map.put(:last_notification_at, nil)
        |> Map.put(:flush_required, true)

      {:error, reason} ->
        Logger.warning(
          "Keeping alert #{snapshot.alert_id} open after recovery failed: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  # The state override is a narrow test seam. Production shard state omits it
  # and always delegates to AlertLifecycle.resolve_alert/4.
  defp resolve_snapshot_alert(snapshot, rule, now, state) do
    resolver = Map.get(state, :resolve_alert, &resolve_alert/4)
    resolver.(snapshot.alert_id, rule, snapshot, now)
  end

  # Like the resolver override, this is a narrow test seam. Production shard
  # state omits it and always delegates to AlertLifecycle.create_event_and_alert/4.
  defp create_snapshot_alert(rule, snapshot, record, now, state) do
    creator = Map.get(state, :create_event_and_alert, &create_event_and_alert/4)
    creator.(rule, snapshot, record, now)
  end

  # Resolve every open snapshot for `rule` whose last matching record predates
  # `cutoff` (the series went silent, so no `anomaly_clear` will arrive) — unless
  # `live_series_keys` marks the snapshot's series as still open in
  # `platform.anomaly_episodes`: event-id dedupe hides add-on heartbeats from the
  # engine, so episode liveness is the staleness source of truth. Reuses
  # `handle_recovery` — the same path a real clear takes — then persists, so the ETS
  # snapshot and Postgres agree. The stale rows are collected before mutating so the
  # `:ets.insert` does not run during the fold.
  def sweep_stale_anomalies(rule, cutoff, now, state, live_series_keys \\ MapSet.new()) do
    stale =
      :ets.foldl(
        fn {key, snapshot}, acc ->
          if snapshot.rule_id == rule.id and is_binary(snapshot.alert_id) and
               stale_snapshot?(snapshot.last_seen_at, cutoff) do
            [{key, snapshot} | acc]
          else
            acc
          end
        end,
        [],
        state.table
      )

    Enum.reduce(stale, 0, fn {key, snapshot}, acc ->
      if live_series?(snapshot, live_series_keys) do
        Logger.debug(
          "Skipping stale-anomaly resolve for #{inspect(key)}: anomaly episode still open"
        )

        acc
      else
        case handle_recovery(snapshot, rule, nil, now, state) do
          {:error, _reason} ->
            acc

          resolved ->
            persist_snapshot(resolved, rule, state)
            :ets.insert(state.table, {key, resolved})
            acc + 1
        end
      end
    end)
  end

  defp live_series?(snapshot, live_series_keys) do
    case Map.get(snapshot, :group_values) do
      %{"anomaly.series_key" => series_key} -> MapSet.member?(live_series_keys, series_key)
      _ -> false
    end
  end

  defp stale_snapshot?(%DateTime{} = last_seen_at, %DateTime{} = cutoff),
    do: DateTime.before?(last_seen_at, cutoff)

  defp stale_snapshot?(_last_seen_at, _cutoff), do: false

  defp maybe_renotify(snapshot, rule, now) do
    renotify_seconds = rule.renotify_seconds || 0
    last_notification = snapshot.last_notification_at || snapshot.last_fired_at

    if (renotify_seconds > 0 and last_notification) &&
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
    if Map.get(snapshot, :bucket_changed, false) || Map.get(snapshot, :flush_required, false) do
      persister = Map.get(state, :persist_snapshot, &persist_snapshot/3)

      case persister.(snapshot, rule, state) do
        :ok ->
          {:ok, snapshot |> Map.put(:bucket_changed, false) |> Map.put(:flush_required, false)}

        :error ->
          {{:error, :snapshot_persistence_failed}, Map.put(snapshot, :flush_required, true)}
      end
    else
      {:ok, snapshot}
    end
  end
end
