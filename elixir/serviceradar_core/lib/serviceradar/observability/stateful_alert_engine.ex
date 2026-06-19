defmodule ServiceRadar.Observability.StatefulAlertEngine do
  @moduledoc """
  Bucketed stateful alert evaluation for log, event, and metric rules.
  """

  use GenServer

  alias Ash.Page.Keyset
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.EventWriter.OCSF
  alias ServiceRadar.Monitoring.Alert
  alias ServiceRadar.Monitoring.AlertGenerator
  alias ServiceRadar.Monitoring.OcsfEvent
  alias ServiceRadar.Monitoring.WebhookNotifier
  alias ServiceRadar.Observability.StatefulAlertRule
  alias ServiceRadar.Observability.StatefulAlertRuleHistory
  alias ServiceRadar.Observability.StatefulAlertRuleState
  alias ServiceRadar.ProcessRegistry

  require Logger

  @rules_cache_ms to_timeout(minute: 1)
  @severity_name_to_id %{
    "emergency" => OCSF.severity_fatal(),
    "fatal" => OCSF.severity_fatal(),
    "critical" => OCSF.severity_critical(),
    "error" => OCSF.severity_high(),
    "high" => OCSF.severity_high(),
    "warning" => OCSF.severity_medium(),
    "medium" => OCSF.severity_medium(),
    "notice" => OCSF.severity_low(),
    "low" => OCSF.severity_low(),
    "info" => OCSF.severity_informational(),
    "informational" => OCSF.severity_informational()
  }
  @diagnostic_sample_limit 5
  @diagnostic_source_limit 10

  # The engine was historically a single Horde singleton GenServer that every
  # event/metric/log batch from every EventWriter processor funnelled through.
  # Because each fired rule performs synchronous `Ash.create`/`Ash.update`
  # writes over TLS *inside* the GenServer's reduction loop, all processors
  # serialized behind one process during DB round-trips, collapsing throughput
  # under modest agent fan-out.
  #
  # The engine is now sharded by `rule_id`. Each shard owns a disjoint subset of
  # rules; a rule's entire state machine and all of its DB writes live in exactly
  # one shard process, serialized exactly as before (so per-rule/per-group
  # ordering and fire-once semantics are byte-for-byte preserved). Different
  # shards run concurrently, so unrelated rules no longer contend on a single
  # process and DB writes parallelize across shards.
  @default_shard_count 8

  @spec evaluate_logs([map()]) :: :ok | {:error, term()}
  def evaluate_logs(rows) when is_list(rows) do
    fan_out(:evaluate_logs, rows)
  end

  @spec evaluate_events([map()]) :: :ok | {:error, term()}
  def evaluate_events(events) when is_list(events) do
    fan_out(:evaluate_events, events)
  end

  @spec evaluate_metrics([map()]) :: :ok | {:error, term()}
  def evaluate_metrics(rows) when is_list(rows) do
    fan_out(:evaluate_metrics, rows)
  end

  @doc "Number of engine shards (configurable, defaults to #{@default_shard_count})."
  @spec shard_count() :: pos_integer()
  def shard_count do
    case Application.get_env(:serviceradar_core, :stateful_alert_engine_shards) do
      count when is_integer(count) and count > 0 -> count
      _ -> @default_shard_count
    end
  end

  @doc "Returns the shard index that owns a given rule id."
  @spec shard_for_rule_id(term()) :: non_neg_integer()
  def shard_for_rule_id(rule_id) do
    :erlang.phash2(rule_id, shard_count())
  end

  def start_link(opts) when is_list(opts) do
    shard = Keyword.fetch!(opts, :shard)
    GenServer.start_link(__MODULE__, %{shard: shard}, name: via_tuple(shard))
  end

  # The batch is sent to every shard. Each shard only evaluates the rules it
  # owns, so records that match no rule in a shard cost just the (in-memory)
  # match check. Shards run concurrently; the call aggregates their replies and
  # surfaces the first error, preserving the previous `:ok | {:error, _}`
  # contract and the "effects are visible when the call returns" guarantee that
  # the integration tests rely on.
  defp fan_out(_message_tag, []), do: :ok

  defp fan_out(message_tag, records) do
    case shard_count() do
      1 ->
        # Sharding disabled: call the single shard directly, no task overhead.
        dispatch_shard(0, message_tag, records)

      shard_count ->
        0..(shard_count - 1)
        |> Task.async_stream(
          fn shard -> dispatch_shard(shard, message_tag, records) end,
          timeout: to_timeout(second: 20),
          on_timeout: :kill_task,
          ordered: false
        )
        |> Enum.reduce(:ok, fn
          {:ok, :ok}, acc -> acc
          {:ok, {:error, reason}}, :ok -> {:error, reason}
          {:ok, {:error, _reason}}, acc -> acc
          {:exit, reason}, :ok -> {:error, {:shard_exit, reason}}
          {:exit, _reason}, acc -> acc
        end)
    end
  end

  defp dispatch_shard(shard, message_tag, records) do
    with {:ok, _pid} <- ensure_started(shard) do
      call(shard, {message_tag, records})
    end
  end

  @impl true
  def init(%{shard: shard} = state) do
    table = :ets.new(:stateful_alert_rule_state, [:set, :private])
    # Simple actor - DB connection's search_path determines the schema
    ash_opts = [actor: SystemActor.system(:alert_engine)]

    state =
      Map.merge(state, %{
        shard: shard,
        table: table,
        rules: [],
        rules_loaded_at: nil,
        ash_opts: ash_opts
      })

    load_state_snapshots(state)

    {:ok, state}
  end

  @impl true
  def handle_call({:evaluate_logs, rows}, _from, state) do
    {state, rules} = load_rules_if_needed(state)

    Enum.each(rows, &process_log_rules(&1, rules, state))

    {:reply, :ok, state}
  rescue
    error ->
      Logger.warning("Stateful alert evaluation failed: #{inspect(error)}")
      {:reply, {:error, error}, state}
  end

  @impl true
  def handle_call({:evaluate_events, events}, _from, state) do
    {state, rules} = load_rules_if_needed(state)

    Enum.each(events, &process_event_rules(&1, rules, state))

    {:reply, :ok, state}
  rescue
    error ->
      Logger.warning("Stateful alert evaluation failed: #{inspect(error)}")
      {:reply, {:error, error}, state}
  end

  @impl true
  def handle_call({:evaluate_metrics, rows}, _from, state) do
    {state, rules} = load_rules_if_needed(state)

    Enum.each(rows, &process_metric_rules(&1, rules, state))

    {:reply, :ok, state}
  rescue
    error ->
      Logger.warning("Stateful alert evaluation failed: #{inspect(error)}")
      {:reply, {:error, error}, state}
  end

  defp call(shard, message) do
    GenServer.call(via_tuple(shard), message, to_timeout(second: 15))
  catch
    :exit, {:noproc, _} ->
      {:error, :engine_not_running}

    :exit, {:timeout, _} ->
      {:error, :engine_timeout}

    :exit, reason ->
      {:error, reason}
  end

  defp ensure_started(shard) do
    case lookup_engine(shard) do
      nil ->
        child_spec = %{
          id: {:stateful_alert_engine, shard},
          start: {__MODULE__, :start_link, [[shard: shard]]},
          restart: :permanent,
          type: :worker
        }

        case ProcessRegistry.start_child(child_spec) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          {:error, reason} -> {:error, reason}
        end

      pid ->
        {:ok, pid}
    end
  end

  defp lookup_engine(shard) do
    case ProcessRegistry.lookup(registry_key(shard)) do
      [{pid, _}] -> pid
      _ -> nil
    end
  end

  defp via_tuple(shard) do
    ProcessRegistry.via(registry_key(shard))
  end

  # Shard 0 keeps the legacy `:stateful_alert_engine` registry key so existing
  # discovery/health tooling and tests that look up the singleton key continue
  # to find a live engine. Additional shards use a tagged key.
  defp registry_key(0), do: :stateful_alert_engine
  defp registry_key(shard), do: {:stateful_alert_engine, shard}

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
    if repo_available?() do
      rules =
        StatefulAlertRule
        |> Ash.Query.for_read(:active, %{})
        |> Ash.read(state.ash_opts)
        |> unwrap_page()
        |> Enum.filter(fn rule -> shard_for_rule_id(rule.id) == state.shard end)

      updated = %{state | rules: rules, rules_loaded_at: System.monotonic_time(:millisecond)}
      {updated, rules}
    else
      {state, []}
    end
  rescue
    error ->
      Logger.warning("Failed to load stateful alert rules: #{inspect(error)}")
      {state, []}
  end

  defp unwrap_page({:ok, %Keyset{results: results}}), do: results
  defp unwrap_page({:ok, results}) when is_list(results), do: results
  defp unwrap_page(_), do: []

  defp load_state_snapshots(state) do
    if repo_available?() do
      StatefulAlertRuleState
      |> Ash.Query.for_read(:read, %{})
      |> Ash.read(state.ash_opts)
      |> case do
        {:ok, %Keyset{results: results}} -> results
        {:ok, results} when is_list(results) -> results
        _ -> []
      end
      |> Enum.filter(fn snapshot -> shard_for_rule_id(snapshot.rule_id) == state.shard end)
      |> Enum.each(fn snapshot ->
        key = {snapshot.rule_id, snapshot.group_key}
        :ets.insert(state.table, {key, normalize_snapshot(snapshot)})
      end)
    end
  rescue
    error ->
      Logger.warning("Failed to load rule snapshots: #{inspect(error)}")
  end

  defp repo_available? do
    Application.get_env(:serviceradar_core, :repo_enabled, true) != false &&
      is_pid(Process.whereis(ServiceRadar.Repo))
  end

  defp normalize_snapshot(snapshot) do
    %{
      rule_id: snapshot.rule_id,
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
      alert_id: snapshot.alert_id,
      first_seen_at: snapshot.last_seen_at,
      diagnostics: empty_diagnostics()
    }
  end

  defp process_log(rule, log, state), do: process_record(rule, log, state)
  defp process_event(rule, event, state), do: process_record(rule, event, state)
  defp process_metric(rule, metric, state), do: process_record(rule, metric, state)

  defp process_log_rules(log, rules, state) do
    Enum.each(rules, &maybe_process_log_rule(log, &1, state))
  end

  defp maybe_process_log_rule(log, %{signal: :log} = rule, state) do
    if rule_matches_log?(log, rule), do: process_log(rule, log, state)
  end

  defp maybe_process_log_rule(_log, _rule, _state), do: :ok

  defp process_event_rules(event, rules, state) do
    if skip_engine_event?(event) do
      :ok
    else
      Enum.each(rules, &maybe_process_event_rule(event, &1, state))
    end
  end

  defp maybe_process_event_rule(event, %{signal: :event} = rule, state) do
    cond do
      rule_matches_event?(event, rule) ->
        process_event(rule, event, state)

      rule_recovers_event?(event, rule) ->
        recover_event(rule, event, state)

      true ->
        :ok
    end
  end

  defp maybe_process_event_rule(_event, _rule, _state), do: :ok

  defp process_metric_rules(metric, rules, state) do
    Enum.each(rules, &maybe_process_metric_rule(metric, &1, state))
  end

  defp maybe_process_metric_rule(metric, %{signal: :metric} = rule, state) do
    if rule_matches_metric?(metric, rule),
      do: process_metric(rule, tag_metric_violation(metric, rule), state)
  end

  defp maybe_process_metric_rule(_metric, _rule, _state), do: :ok

  defp process_record(rule, record, state) do
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

  defp recover_event(rule, record, state) do
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
              |> handle_recovery(rule, record, now)

            flushed = maybe_flush_snapshot(snapshot, rule, state)
            :ets.insert(state.table, {key, flushed})

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

  defp update_snapshot(snapshot, rule, record) do
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
      is_binary(snapshot.alert_id) and incident_rollover?(snapshot, rule, now) ->
        rollover_incident(snapshot, rule, record, now)

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
        case create_event_and_alert(rule, snapshot, record, now) do
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
            snapshot
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

  defp rollover_incident(snapshot, rule, record, now) do
    _ = resolve_alert(snapshot.alert_id, rule, snapshot, now)

    refreshed_snapshot =
      snapshot
      |> Map.put(:alert_id, nil)
      |> Map.put(:last_notification_at, nil)
      |> Map.put(:cooldown_until, nil)
      |> Map.put(:first_seen_at, now)
      |> Map.put(:diagnostics, update_diagnostics(empty_diagnostics(), record, now))
      |> Map.put(:flush_required, true)

    handle_firing(refreshed_snapshot, rule, record, now)
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

  defp create_event_and_alert(rule, snapshot, record, now) do
    event = build_event(rule, snapshot, record, now)
    # DB connection's search_path determines the schema
    actor = SystemActor.system(:alert_engine)

    with {:ok, ocsf_event} <- record_event(event, actor) do
      case AlertGenerator.from_event(ocsf_event, actor: actor, alert: rule.alert) do
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

  defp record_event(attrs, actor) do
    # DB connection's search_path determines the schema
    OcsfEvent
    |> Ash.Changeset.for_create(:record, attrs, actor: actor)
    |> Ash.create()
  end

  defp resolve_alert(alert_id, rule, snapshot, now) when is_binary(alert_id) do
    # DB connection's search_path determines the schema
    actor = SystemActor.system(:alert_engine)

    case Alert.get_by_id(alert_id, actor: actor) do
      {:ok, alert} ->
        alert
        |> Ash.Changeset.for_update(:resolve, %{resolved_by: "system"}, actor: actor)
        |> Ash.update()
        |> case do
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

  defp resolve_alert(_alert_id, _rule, _snapshot, _now), do: :ok

  defp send_renotify(alert_id, _rule, _snapshot, now) when is_binary(alert_id) do
    # DB connection's search_path determines the schema
    actor = SystemActor.system(:alert_engine)

    case Alert.get_by_id(alert_id, actor: actor) do
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
        |> Ash.Changeset.for_update(:record_notification, %{}, actor: actor)
        |> Ash.update()

        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp send_renotify(_alert_id, _rule, _snapshot, _now), do: {:error, :missing_alert_id}

  defp sync_active_incident(snapshot, rule, now, opts \\ []) do
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

  defp severity_to_level(:emergency), do: :error
  defp severity_to_level(:critical), do: :error
  defp severity_to_level(:warning), do: :warning
  defp severity_to_level(:info), do: :info
  defp severity_to_level(_), do: :warning

  defp build_event(rule, snapshot, record, now) do
    activity_id = OCSF.activity_log_create()
    class_uid = OCSF.class_event_log_activity()
    category_uid = OCSF.category_system_activity()
    severity_id = severity_id(rule.alert)
    message_override = rule.event["message"] || rule.event[:message]

    message =
      message_override ||
        "Stateful rule #{rule.name} triggered for #{snapshot.group_key} (#{snapshot.window_count}/#{rule.threshold} in #{rule.window_seconds}s)"

    source = source_record_details(record)
    diagnostics = diagnostic_summary(rule, snapshot, now, source)

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
            version: "1.7.0",
            product_name: "ServiceRadar Core",
            correlation_uid: "stateful_rule:#{rule.id}:#{snapshot.group_key}"
          ]
          |> OCSF.build_metadata()
          |> Map.put(:serviceradar, %{
            stateful_rule: true,
            rule_id: to_string(rule.id),
            group_key: snapshot.group_key,
            diagnostics: diagnostics
          }),
        actor: OCSF.build_actor(app_name: "serviceradar.core", process: "stateful_alert_engine"),
        log_name: rule.event["log_name"] || rule.event[:log_name] || "alert.rule.threshold",
        log_provider: "serviceradar.core",
        log_level: log_level_for_severity(severity_id)
      },
      :unmapped,
      build_unmapped(rule, snapshot, source, diagnostics)
    )
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

  defp empty_diagnostics do
    %{
      "source_event_ids" => [],
      "samples" => %{
        "processes" => [],
        "containers" => [],
        "kubernetes" => []
      }
    }
  end

  defp update_diagnostics(nil, record, now),
    do: update_diagnostics(empty_diagnostics(), record, now)

  defp update_diagnostics(diagnostics, record, now) when is_map(diagnostics) do
    context = record_diagnostic_context(record)
    source_event_id = source_event_id(record)
    source = source_record_details(record)

    diagnostics
    |> Map.put_new("source_event_ids", [])
    |> Map.put_new("samples", empty_diagnostics()["samples"])
    |> Map.put("latest_source", source)
    |> update_in(
      ["source_event_ids"],
      &add_bounded_value(&1, source_event_id, @diagnostic_source_limit)
    )
    |> update_in(["samples"], &update_diagnostic_samples(&1, context, now))
  end

  defp update_diagnostics(_diagnostics, record, now),
    do: update_diagnostics(empty_diagnostics(), record, now)

  defp update_diagnostic_samples(samples, context, now) when is_map(samples) do
    samples
    |> Map.put_new("processes", [])
    |> Map.put_new("containers", [])
    |> Map.put_new("kubernetes", [])
    |> update_in(
      ["processes"],
      &add_bounded_value(&1, process_sample(context, now), @diagnostic_sample_limit)
    )
    |> update_in(
      ["containers"],
      &add_bounded_value(&1, container_sample(context, now), @diagnostic_sample_limit)
    )
    |> update_in(
      ["kubernetes"],
      &add_bounded_value(&1, kubernetes_sample(context, now), @diagnostic_sample_limit)
    )
  end

  defp update_diagnostic_samples(_samples, context, now) do
    update_diagnostic_samples(empty_diagnostics()["samples"], context, now)
  end

  defp record_diagnostic_context(record) do
    metadata = fetch_attr(record, :metadata) || %{}
    unmapped = event_unmapped(record)
    signal = map_value(metadata, "security_signal") || %{}
    falco = map_value(unmapped, "falco") || %{}

    diagnostic_payload =
      map_value(signal, "diagnostics") ||
        map_value(falco, "diagnostics") ||
        %{}

    %{
      "rule" => map_value(diagnostic_payload, "rule") || fallback_rule(record),
      "host" => map_value(diagnostic_payload, "host") || fallback_host(record),
      "process" => map_value(diagnostic_payload, "process") || %{},
      "parent_process" => map_value(diagnostic_payload, "parent_process") || %{},
      "container" => map_value(diagnostic_payload, "container") || fallback_container(record),
      "kubernetes" => map_value(diagnostic_payload, "kubernetes") || fallback_kubernetes(record),
      "attribution" => map_value(diagnostic_payload, "attribution") || %{}
    }
  end

  defp process_sample(context, now) do
    process = map_value(context, "process") || %{}
    parent = map_value(context, "parent_process") || %{}

    compact_map(%{
      "name" => map_value(process, "name"),
      "parent" => map_value(parent, "name"),
      "command" => map_value(process, "command"),
      "cwd" => map_value(process, "cwd"),
      "executable" => map_value(process, "executable"),
      "executable_flags" => map_value(process, "executable_flags"),
      "observed_at" => iso8601(now)
    })
  end

  defp container_sample(context, now) do
    container = map_value(context, "container") || %{}

    compact_map(%{
      "id" => map_value(container, "id"),
      "name" => map_value(container, "name"),
      "image" => map_value(container, "image"),
      "image_repository" => map_value(container, "image_repository"),
      "image_tag" => map_value(container, "image_tag"),
      "observed_at" => iso8601(now)
    })
  end

  defp kubernetes_sample(context, now) do
    kubernetes = map_value(context, "kubernetes") || %{}
    attribution = map_value(context, "attribution") || %{}

    compact_map(%{
      "namespace" => map_value(kubernetes, "namespace"),
      "pod" => map_value(kubernetes, "pod"),
      "attribution_status" => map_value(attribution, "status"),
      "missing" => map_value(attribution, "missing"),
      "observed_at" => iso8601(now)
    })
  end

  defp diagnostic_summary(rule, snapshot, now, source \\ nil) do
    diagnostics = snapshot.diagnostics || empty_diagnostics()
    first_seen_at = snapshot.first_seen_at || now
    last_seen_at = snapshot.last_seen_at || now
    source = source || Map.get(diagnostics, "latest_source", %{})

    compact_map(%{
      "rule_id" => to_string(rule.id),
      "rule_name" => rule.name,
      "group_key" => snapshot.group_key,
      "group_values" => snapshot.group_values || %{},
      "threshold" => rule.threshold,
      "window_seconds" => rule.window_seconds,
      "bucket_seconds" => rule.bucket_seconds,
      "window_count" => snapshot.window_count || 0,
      "first_seen_at" => iso8601(first_seen_at),
      "last_seen_at" => iso8601(last_seen_at),
      "representative_event_ids" => Map.get(diagnostics, "source_event_ids", []),
      "samples" => Map.get(diagnostics, "samples", %{}),
      "source" => source
    })
  end

  defp fallback_rule(record) do
    metadata = fetch_attr(record, :metadata) || %{}
    unmapped = event_unmapped(record)

    compact_map(%{
      "name" => map_value(metadata, "rule") || map_value(unmapped, "rule"),
      "priority" => map_value(metadata, "priority") || map_value(unmapped, "priority")
    })
  end

  defp fallback_host(record) do
    metadata = fetch_attr(record, :metadata) || %{}
    unmapped = event_unmapped(record)

    compact_map(%{
      "name" => map_value(metadata, "hostname") || map_value(unmapped, "hostname")
    })
  end

  defp fallback_container(record) do
    unmapped = event_unmapped(record)
    falco = map_value(unmapped, "falco") || %{}

    compact_map(%{
      "id" => map_value(falco, "container_id") || map_value(unmapped, "container_id"),
      "name" => map_value(falco, "container") || map_value(unmapped, "container")
    })
  end

  defp fallback_kubernetes(record) do
    unmapped = event_unmapped(record)
    falco = map_value(unmapped, "falco") || %{}

    compact_map(%{
      "namespace" => map_value(falco, "namespace") || map_value(unmapped, "namespace"),
      "pod" => map_value(falco, "pod") || map_value(unmapped, "pod")
    })
  end

  defp source_event_id(record) do
    case fetch_attr(record, :id) do
      nil -> nil
      id -> to_string(id)
    end
  end

  defp add_bounded_value(values, nil, _limit), do: values || []
  defp add_bounded_value(values, %{} = value, _limit) when map_size(value) == 0, do: values || []
  defp add_bounded_value(values, [] = _value, _limit), do: values || []

  defp add_bounded_value(values, value, limit) do
    values = if is_list(values), do: values, else: []

    if Enum.member?(values, value) do
      values
    else
      Enum.take(values ++ [value], limit)
    end
  end

  defp map_value(map, key) when is_map(map) and is_binary(key) do
    Map.get(map, key) || fetch_existing_atom_key(map, key)
  end

  defp map_value(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp map_value(_map, _key), do: nil

  defp fetch_existing_atom_key(map, key) do
    Map.get(map, String.to_existing_atom(key))
  rescue
    ArgumentError -> nil
  end

  defp compact_map(map) when is_map(map) do
    Enum.reduce(map, %{}, fn {key, value}, acc ->
      value = compact_value(value)

      if empty_value?(value) do
        acc
      else
        Map.put(acc, key, value)
      end
    end)
  end

  defp compact_value(%DateTime{} = value), do: iso8601(value)
  defp compact_value(value) when is_map(value), do: compact_map(value)
  defp compact_value(value) when is_list(value), do: Enum.reject(value, &empty_value?/1)
  defp compact_value(value), do: value

  defp empty_value?(nil), do: true
  defp empty_value?(""), do: true
  defp empty_value?(%{} = value), do: map_size(value) == 0
  defp empty_value?(value) when is_list(value), do: value == []
  defp empty_value?(_value), do: false

  defp iso8601(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp iso8601(value), do: value

  defp severity_id(alert_overrides) do
    overrides = alert_overrides || %{}

    severity =
      overrides["severity"] ||
        overrides["severity_id"] ||
        overrides[:severity] ||
        overrides[:severity_id] ||
        :warning

    resolve_severity_id(severity)
  end

  defp resolve_severity_id(severity) when is_integer(severity) and severity in 1..6, do: severity

  defp resolve_severity_id(severity) when is_atom(severity) do
    severity
    |> Atom.to_string()
    |> resolve_severity_id()
  end

  defp resolve_severity_id(severity) when is_binary(severity) do
    Map.get(@severity_name_to_id, String.downcase(severity), OCSF.severity_medium())
  end

  defp resolve_severity_id(_), do: OCSF.severity_medium()

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

  defp rule_matches_log?(log, rule) do
    match = rule.match || %{}

    if match["always"] == true do
      true
    else
      log_matches?(log, match)
    end
  end

  defp rule_matches_event?(event, rule) do
    match = rule.match || %{}

    if match["always"] == true do
      true
    else
      event_matches?(event, match)
    end
  end

  defp rule_recovers_event?(event, rule) do
    case rule.match || %{} do
      %{"recovery" => recovery} when is_map(recovery) -> event_matches?(event, recovery)
      _ -> false
    end
  end

  defp rule_matches_metric?(metric, rule) do
    match = rule.match || %{}

    if match["always"] == true do
      true
    else
      metric_matches?(metric, match)
    end
  end

  defp log_matches?(log, match) do
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

  defp event_matches?(event, match) do
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

  defp metric_matches?(metric, match) do
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

  defp match_metric_field(_metric, _field, nil), do: true

  defp match_metric_field(metric, field, expected),
    do: match_value(fetch_attr(metric, field), expected)

  defp tag_metric_violation(metric, rule) do
    {violated?, details} = metric_condition_result(metric, rule.match || %{})

    metric
    |> Map.put(:__stateful_alert_violation__, violated?)
    |> Map.put(:__stateful_alert_condition__, details)
  end

  defp metric_condition_result(metric, match) do
    condition = metric_condition(match)

    if map_size(condition) == 0 do
      {true, %{}}
    else
      value = metric_number(fetch_attr(metric, :value))
      threshold = metric_threshold(metric, condition)
      comparison = metric_comparison(condition)
      violated? = compare_metric_value(value, threshold, comparison)

      details =
        compact_map(%{
          "value" => value,
          "comparison" => comparison,
          "threshold" => threshold,
          "baseline_value" => metric_baseline(metric, condition),
          "baseline_multiplier" => condition_number(condition, "baseline_multiplier", 1.0),
          "baseline_offset" => condition_number(condition, "baseline_offset", 0.0)
        })

      {violated?, details}
    end
  end

  defp metric_condition(match) do
    cond do
      is_map(match["condition"]) -> match["condition"]
      is_map(match["metric_condition"]) -> match["metric_condition"]
      is_map(match["threshold_condition"]) -> match["threshold_condition"]
      true -> %{}
    end
  end

  defp metric_threshold(metric, condition) do
    explicit =
      condition_number(condition, "threshold") ||
        condition_number(condition, "value")

    case explicit do
      nil ->
        case metric_baseline(metric, condition) do
          nil ->
            nil

          baseline ->
            multiplier = condition_number(condition, "baseline_multiplier", 1.0)
            offset = condition_number(condition, "baseline_offset", 0.0)
            baseline * multiplier + offset
        end

      threshold ->
        threshold
    end
  end

  defp metric_baseline(metric, condition) do
    condition_number(condition, "baseline_value") ||
      condition_number(condition, "baseline") ||
      metric_baseline_from_path(metric, condition)
  end

  defp metric_baseline_from_path(metric, condition) do
    case condition["baseline_path"] || condition[:baseline_path] do
      path when is_binary(path) -> metric_number(get_nested_value(metric_match_map(metric), path))
      _ -> nil
    end
  end

  defp condition_number(condition, key), do: condition_number(condition, key, nil)

  defp condition_number(condition, key, default) when is_map(condition) do
    case Map.get(condition, key) || Map.get(condition, String.to_existing_atom(key)) do
      nil -> default
      value -> metric_number(value) || default
    end
  rescue
    ArgumentError -> default
  end

  defp metric_number(value) when is_integer(value), do: value / 1
  defp metric_number(value) when is_float(value), do: value

  defp metric_number(value) when is_binary(value) do
    case Float.parse(value) do
      {parsed, ""} -> parsed
      {parsed, _rest} -> parsed
      :error -> nil
    end
  end

  defp metric_number(_value), do: nil

  defp metric_comparison(condition) do
    comparison = condition["comparison"] || condition[:comparison] || "gt"

    comparison
    |> to_string()
    |> String.downcase()
  end

  defp compare_metric_value(nil, _threshold, _comparison), do: false
  defp compare_metric_value(_value, nil, _comparison), do: false

  defp compare_metric_value(value, threshold, comparison) when comparison in ["gt", ">"],
    do: value > threshold

  defp compare_metric_value(value, threshold, comparison) when comparison in ["gte", "ge", ">="],
    do: value >= threshold

  defp compare_metric_value(value, threshold, comparison) when comparison in ["lt", "<"],
    do: value < threshold

  defp compare_metric_value(value, threshold, comparison) when comparison in ["lte", "le", "<="],
    do: value <= threshold

  defp compare_metric_value(value, threshold, comparison) when comparison in ["eq", "=="],
    do: value == threshold

  defp compare_metric_value(value, threshold, comparison) when comparison in ["neq", "!="],
    do: value != threshold

  defp compare_metric_value(_value, _threshold, _comparison), do: false

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
      nil ->
        true

      needle when is_binary(needle) ->
        body = body || ""
        String.contains?(String.downcase(body), String.downcase(needle))

      _ ->
        false
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

  defp build_group(nil, _log), do: {:ok, "global", %{}}
  defp build_group([], _log), do: {:ok, "global", %{}}

  defp build_group(keys, record) when is_list(keys) do
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

  defp group_sources(record) do
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

  defp group_value_for_key(key, record, sources) do
    sources
    |> group_source_list()
    |> Enum.find_value(fn source -> get_nested_value(source, key) end)
    |> case do
      nil -> record_field_value(record, key)
      value -> value
    end
  end

  defp group_source_list(sources) do
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

  defp record_timestamp(record) do
    record_datetime(record, :time) || record_datetime(record, :timestamp) || DateTime.utc_now()
  end

  defp record_datetime(record, key) do
    case fetch_attr(record, key) do
      %DateTime{} = dt -> dt
      _ -> nil
    end
  end

  defp record_field_value(record, "service_name"),
    do: fetch_attr(record, :service_name) || fetch_attr(record, :log_provider)

  defp record_field_value(record, "severity_text"),
    do: fetch_attr(record, :severity_text) || fetch_attr(record, :severity)

  defp record_field_value(record, "severity_number"),
    do: fetch_attr(record, :severity_number) || fetch_attr(record, :severity_id)

  defp record_field_value(record, "body"),
    do: fetch_attr(record, :body) || fetch_attr(record, :message)

  defp record_field_value(record, "log_name"), do: fetch_attr(record, :log_name)
  defp record_field_value(record, "log_provider"), do: fetch_attr(record, :log_provider)

  defp record_field_value(record, "metric_name"), do: fetch_attr(record, :metric_name)
  defp record_field_value(record, "metric_type"), do: fetch_attr(record, :metric_type)
  defp record_field_value(record, "unit"), do: fetch_attr(record, :unit)
  defp record_field_value(record, "device"), do: record_device_uid(record)
  defp record_field_value(record, "device.uid"), do: record_device_uid(record)

  defp record_field_value(record, "device_uid"),
    do: fetch_attr(record, :device_uid) || record_device_uid(record)

  defp record_field_value(record, "device_id"), do: fetch_attr(record, :device_id)
  defp record_field_value(record, "agent_id"), do: fetch_attr(record, :agent_id)
  defp record_field_value(record, "gateway_id"), do: fetch_attr(record, :gateway_id)
  defp record_field_value(record, "partition"), do: fetch_attr(record, :partition)
  defp record_field_value(record, "series_key"), do: fetch_attr(record, :series_key)

  defp record_field_value(record, "serviceradar.metric"), do: fetch_attr(record, :metric_name)

  defp record_field_value(record, "serviceradar.metric_name"),
    do: fetch_attr(record, :metric_name)

  defp record_field_value(record, "serviceradar.metric_type"),
    do: fetch_attr(record, :metric_type)

  defp record_field_value(record, "serviceradar.device_id"), do: fetch_attr(record, :device_id)

  defp record_field_value(record, "serviceradar.device_uid"),
    do: fetch_attr(record, :device_uid) || record_device_uid(record)

  defp record_field_value(record, "serviceradar.agent_id"), do: fetch_attr(record, :agent_id)

  defp record_field_value(record, "serviceradar.gateway_id"), do: fetch_attr(record, :gateway_id)

  defp record_field_value(_record, _key), do: nil

  defp record_device(record) do
    case fetch_attr(record, :device) do
      %{} = device -> device
      _ -> %{}
    end
  end

  defp record_device_uid(record) do
    record
    |> record_device()
    |> map_value("uid")
  end

  defp fetch_attr(map, key) when is_map(map) and is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp fetch_attr(_map, _key), do: nil

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

  defp record_bucket_increment(record) do
    if metric_record?(record) do
      if fetch_attr(record, :__stateful_alert_violation__) do
        1
      else
        0
      end
    else
      1
    end
  end

  defp normalize_bucket_counts(bucket_counts) when is_map(bucket_counts) do
    Enum.reduce(bucket_counts, %{}, fn {key, value}, acc ->
      case Integer.parse(to_string(key)) do
        {bucket, _} -> Map.put(acc, bucket, value)
        :error -> acc
      end
    end)
  end

  defp stringify_bucket_counts(bucket_counts) do
    Enum.reduce(bucket_counts, %{}, fn {key, value}, acc ->
      Map.put(acc, to_string(key), value)
    end)
  end

  defp add_seconds(%DateTime{} = dt, seconds) when is_integer(seconds) do
    DateTime.add(dt, seconds, :second)
  end

  defp skip_engine_event?(event) do
    stateful_rule_event?(event) or engine_generated_event?(event)
  end

  defp source_record_details(record) do
    cond do
      metric_record?(record) -> metric_source_details(record)
      record_has_time?(record) -> event_source_details(record)
      true -> log_source_details(record)
    end
  end

  defp stateful_rule_event?(event) do
    metadata = fetch_attr(event, :metadata) || %{}
    serviceradar = fetch_attr(metadata, :serviceradar) || %{}
    fetch_attr(serviceradar, :stateful_rule) == true
  end

  defp engine_generated_event?(event) do
    fetch_attr(event, :log_name) == "alert.rule.threshold" and
      fetch_attr(event, :log_provider) == "serviceradar.core"
  end

  defp record_has_time?(record) do
    Map.has_key?(record, :time) || Map.has_key?(record, "time")
  end

  defp metric_record?(record) do
    not is_nil(fetch_attr(record, :metric_name)) or
      not is_nil(fetch_attr(record, :metric_type)) or
      Map.has_key?(record, :__stateful_alert_violation__)
  end

  defp event_source_details(record) do
    %{
      "source_signal" => "event",
      "source_event_id" => to_string(fetch_attr(record, :id)),
      "source_event_time" => fetch_attr(record, :time),
      "source_log_name" => fetch_attr(record, :log_name),
      "source_log_provider" => fetch_attr(record, :log_provider)
    }
  end

  defp log_source_details(record) do
    %{
      "source_signal" => "log",
      "source_log_id" => to_string(fetch_attr(record, :id)),
      "source_log_time" => fetch_attr(record, :timestamp),
      "source_service" => fetch_attr(record, :service_name)
    }
  end

  defp metric_source_details(record) do
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

    Map.get(unmapped, "log_resource_attributes") || Map.get(unmapped, :log_resource_attributes) ||
      %{}
  end

  defp event_unmapped(event) do
    Map.get(event, :unmapped) || Map.get(event, "unmapped") || %{}
  end

  defp metric_match_sources(metric) do
    {metric_match_map(metric), metric_resource_attributes(metric)}
  end

  defp metric_match_map(metric) do
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

  defp metric_resource_attributes(metric) do
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
end
