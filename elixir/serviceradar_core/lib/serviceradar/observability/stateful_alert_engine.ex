defmodule ServiceRadar.Observability.StatefulAlertEngine do
  @moduledoc """
  Bucketed stateful alert evaluation for log, event, and metric rules.

  This module is the sharded GenServer front door: it owns sharding/fan-out, the
  GenServer lifecycle, and loading rules and snapshots for the rules a shard
  owns. The evaluation work is decomposed into focused sibling modules under
  `ServiceRadar.Observability.StatefulAlertEngine.*`:

    * `RuleMatcher` / `MetricCondition` — does a record match a rule?
    * `Record` / `Bucketing` — record field extraction, grouping, and windowing
    * `StateMachine` — per-rule snapshot advance, fire/recover/renotify dispatch
    * `AlertLifecycle` — OCSF event/alert/incident/history/snapshot persistence
    * `Diagnostics` / `Severity` — incident diagnostics and severity resolution
    * `EdgeAnomalyDisposition` — seasonal disposition for edge-spike anomalies

  Behavior is identical to the previous single-module implementation; the split
  is a structural extraction only.
  """

  use GenServer

  alias Ash.Page.Keyset
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Observability.StatefulAlertEngine.Bucketing
  alias ServiceRadar.Observability.StatefulAlertEngine.Diagnostics
  alias ServiceRadar.Observability.StatefulAlertEngine.EdgeAnomalyDisposition
  alias ServiceRadar.Observability.StatefulAlertEngine.StateMachine
  alias ServiceRadar.Observability.StatefulAlertRule
  alias ServiceRadar.Observability.StatefulAlertRuleState
  alias ServiceRadar.ProcessRegistry

  require Logger

  @rules_cache_ms to_timeout(minute: 1)

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

  # Backward-compatible re-exports of the edge-anomaly seasonal-disposition API,
  # which now lives in `EdgeAnomalyDisposition`. External callers (and tests)
  # continue to use `StatefulAlertEngine.<fun>`.
  @doc false
  defdelegate seasonal_disposition_suppresses_edge_anomaly?(event, rule),
    to: EdgeAnomalyDisposition

  @doc false
  defdelegate seasonal_disposition_action_for_edge_anomaly(event, rule),
    to: EdgeAnomalyDisposition

  @doc false
  defdelegate seasonal_disposition_for_edge_anomaly(event, rule), to: EdgeAnomalyDisposition

  @doc false
  defdelegate tag_edge_anomaly_disposition(event, action, attrs, disposition),
    to: EdgeAnomalyDisposition

  @doc false
  defdelegate seasonal_disposition_action(disposition), to: EdgeAnomalyDisposition

  @doc """
  Auto-resolve open alerts for `rule_name` whose group has had no matching record
  since `cutoff`. Used for the edge-spike anomaly rule: when a monitored series goes
  silent (an ephemeral pod is destroyed, a host is decommissioned, or the edge
  add-on evicts the series at its memory cap) no `anomaly_clear` ever arrives, so the
  alert would otherwise sit open until manual cleanup.

  Engine silence is not proof of staleness: event-id dedupe hides add-on heartbeats
  for still-open anomalies. `live_series_keys` carries the series keys of anomaly
  episodes that are still open (per `platform.anomaly_episodes`); alerts grouped on
  those series are kept, everything else past `cutoff` resolves.

  Runs inside each owning shard and reuses the exact resolve path a real
  `anomaly_clear` takes (`handle_recovery`), so the in-memory ETS snapshot and the
  Postgres `alert_id` stay consistent — a later re-anomaly of the same series opens a
  fresh alert rather than being suppressed by a stale snapshot. Returns the count
  resolved across all shards.
  """
  @spec resolve_stale_anomalies(String.t(), DateTime.t(), DateTime.t(), MapSet.t()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def resolve_stale_anomalies(
        rule_name,
        %DateTime{} = cutoff,
        %DateTime{} = now,
        %MapSet{} = live_series_keys \\ MapSet.new()
      )
      when is_binary(rule_name) do
    fan_out_resolve({:resolve_stale_anomalies, {rule_name, cutoff, now, live_series_keys}})
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

  # Like `fan_out`, but for the resolve-stale sweep: each shard returns the count it
  # resolved (only the shard owning the rule resolves anything), and we sum them.
  defp fan_out_resolve(message) do
    case shard_count() do
      1 ->
        dispatch_resolve_shard(0, message)

      shard_count ->
        0..(shard_count - 1)
        |> Task.async_stream(
          fn shard -> dispatch_resolve_shard(shard, message) end,
          timeout: to_timeout(second: 20),
          on_timeout: :kill_task,
          ordered: false
        )
        |> Enum.reduce({:ok, 0}, fn
          {:ok, {:ok, n}}, {:ok, acc} -> {:ok, acc + n}
          {:ok, {:error, reason}}, {:ok, _acc} -> {:error, reason}
          {:ok, _}, acc -> acc
          {:exit, reason}, {:ok, _acc} -> {:error, {:shard_exit, reason}}
          {:exit, _reason}, acc -> acc
        end)
    end
  end

  defp dispatch_resolve_shard(shard, message) do
    with {:ok, _pid} <- ensure_started(shard) do
      call(shard, message)
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
        snapshots_loaded?: false,
        rules_loaded_at: nil,
        ash_opts: ash_opts,
        repo_unavailable_logged: false,
        rules_load_error_logged: false
      })

    {:ok, state}
  end

  @impl true
  def handle_call({:evaluate_logs, rows}, _from, state) do
    case load_rules_if_needed(state) do
      {:ok, state, rules} ->
        result = process_records(rows, &StateMachine.process_log_rules(&1, rules, state))
        {:reply, result, state}

      {:error, reason, state} ->
        {:reply, {:error, reason}, state}
    end
  rescue
    error ->
      Logger.warning("Stateful alert evaluation failed: #{inspect(error)}")
      {:reply, {:error, error}, state}
  end

  @impl true
  def handle_call({:evaluate_events, events}, _from, state) do
    case load_rules_if_needed(state) do
      {:ok, state, rules} ->
        result = process_records(events, &StateMachine.process_event_rules(&1, rules, state))
        {:reply, result, state}

      {:error, reason, state} ->
        {:reply, {:error, reason}, state}
    end
  rescue
    error ->
      Logger.warning("Stateful alert evaluation failed: #{inspect(error)}")
      {:reply, {:error, error}, state}
  end

  @impl true
  def handle_call({:evaluate_metrics, rows}, _from, state) do
    case load_rules_if_needed(state) do
      {:ok, state, rules} ->
        result = process_records(rows, &StateMachine.process_metric_rules(&1, rules, state))
        {:reply, result, state}

      {:error, reason, state} ->
        {:reply, {:error, reason}, state}
    end
  rescue
    error ->
      Logger.warning("Stateful alert evaluation failed: #{inspect(error)}")
      {:reply, {:error, error}, state}
  end

  @impl true
  def handle_call(
        {:resolve_stale_anomalies, {rule_name, cutoff, now, live_series_keys}},
        _from,
        state
      ) do
    case load_rules_if_needed(state) do
      {:ok, state, rules} ->
        # Only the shard that owns the rule will find it in its loaded set.
        resolved =
          case Enum.find(rules, fn rule -> rule.name == rule_name end) do
            nil -> 0
            rule -> StateMachine.sweep_stale_anomalies(rule, cutoff, now, state, live_series_keys)
          end

        {:reply, {:ok, resolved}, state}

      {:error, reason, state} ->
        {:reply, {:error, reason}, state}
    end
  rescue
    error ->
      Logger.warning("Stale-anomaly auto-resolve failed: #{inspect(error)}")
      {:reply, {:error, error}, state}
  end

  # Rolling-deploy compat: shards are Horde-placed cluster-wide, so during a
  # rolling deploy a worker on an old node can reach a shard running this code
  # with the legacy 3-tuple (no live-set). Treat it as an empty live-set sweep,
  # which is exactly the pre-live-set behavior. The reverse skew — this node's
  # 4-tuple reaching an old-code shard — cannot be patched here: the old shard
  # crashes with a FunctionClauseError, the caller's `call/2` catch maps the
  # exit to `{:error, _}` (so the Oban job retries instead of crashing), Horde
  # restarts the shard, and the next 30-minute sweep after the deploy finishes
  # succeeds. The tradeoff is bounded by the sweep cadence.
  @impl true
  def handle_call({:resolve_stale_anomalies, {rule_name, cutoff, now}}, from, state) do
    handle_call({:resolve_stale_anomalies, {rule_name, cutoff, now, MapSet.new()}}, from, state)
  end

  defp process_records(records, process) do
    Enum.reduce(records, :ok, fn record, result ->
      case process.(record) do
        :ok -> result
        {:error, _} = error -> if result == :ok, do: error, else: result
      end
    end)
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

  defp load_rules_if_needed(state) do
    with {:ok, state} <- load_state_snapshots(state) do
      load_cached_rules(state)
    end
  end

  defp load_cached_rules(%{rules_loaded_at: nil} = state) do
    load_rules(state)
  end

  defp load_cached_rules(state) do
    now = System.monotonic_time(:millisecond)

    if now - state.rules_loaded_at > @rules_cache_ms do
      load_rules(state)
    else
      {:ok, state, state.rules}
    end
  end

  defp load_rules(state) do
    if repo_available?() do
      case read_active_rules(state) do
        {:ok, results} ->
          rules =
            Enum.filter(results, fn rule -> shard_for_rule_id(rule.id) == state.shard end)

          :telemetry.execute(
            [:serviceradar, :stateful_alert_engine, :rules_loaded],
            %{count: length(rules)},
            %{shard: state.shard}
          )

          if state.rules_load_error_logged do
            Logger.info(
              "StatefulAlertEngine shard #{state.shard} recovered: loaded #{length(rules)} rules"
            )
          end

          updated = %{
            state
            | rules: rules,
              rules_loaded_at: System.monotonic_time(:millisecond),
              rules_load_error_logged: false
          }

          {:ok, updated, rules}

        {:error, error} ->
          :telemetry.execute(
            [:serviceradar, :stateful_alert_engine, :rules_load_failed],
            %{count: 1},
            %{shard: state.shard, node: node()}
          )

          state =
            if state.rules_load_error_logged do
              state
            else
              Logger.error(
                "StatefulAlertEngine shard #{state.shard} failed to load alert rules; " <>
                  "keeping #{length(state.rules)} previously loaded rules: #{inspect(error)}"
              )

              %{state | rules_load_error_logged: true}
            end

          rules_load_failure(state, error)
      end
    else
      {:error, :repo_unavailable, report_repo_unavailable(state)}
    end
  rescue
    error ->
      Logger.error("Failed to load stateful alert rules: #{inspect(error)}")
      rules_load_failure(state, error)
  end

  defp rules_load_failure(%{rules_loaded_at: nil} = state, error),
    do: {:error, {:rules_load_failed, error}, state}

  defp rules_load_failure(state, _error), do: {:ok, state, state.rules}

  defp read_active_rules(%{rules_reader: reader}) when is_function(reader, 0), do: reader.()

  defp read_active_rules(state) do
    StatefulAlertRule
    |> Ash.Query.for_read(:active, %{})
    |> Ash.read(state.ash_opts)
    |> case do
      {:ok, %Keyset{results: results}} -> {:ok, results}
      {:ok, results} when is_list(results) -> {:ok, results}
      {:error, error} -> {:error, error}
      other -> {:error, other}
    end
  end

  # A shard hosted on a repo-less node (gateway/web tiers) evaluates every batch
  # against zero rules, silently dropping alerts. Warn once per shard process and
  # count every occurrence so dashboards can spot misplaced shards.
  defp report_repo_unavailable(state) do
    :telemetry.execute(
      [:serviceradar, :stateful_alert_engine, :repo_unavailable],
      %{count: 1},
      %{shard: state.shard, node: node()}
    )

    if state.repo_unavailable_logged do
      state
    else
      Logger.warning(
        "StatefulAlertEngine shard #{state.shard} on #{node()} has no repo available; " <>
          "cannot evaluate alert rules"
      )

      %{state | repo_unavailable_logged: true}
    end
  end

  defp load_state_snapshots(%{snapshots_loaded?: true} = state), do: {:ok, state}

  defp load_state_snapshots(state) do
    if repo_available?() do
      case read_state_snapshots(state) do
        {:ok, results} ->
          snapshots =
            results
            |> Enum.filter(fn snapshot -> shard_for_rule_id(snapshot.rule_id) == state.shard end)
            |> Enum.map(fn snapshot ->
              {{snapshot.rule_id, snapshot.group_key}, normalize_snapshot(snapshot)}
            end)

          :ets.insert(state.table, snapshots)
          {:ok, %{state | snapshots_loaded?: true}}

        {:error, reason} ->
          {:error, {:snapshot_restore_failed, reason}, state}
      end
    else
      {:error, :repo_unavailable, report_repo_unavailable(state)}
    end
  rescue
    error ->
      Logger.warning("Failed to load rule snapshots: #{inspect(error)}")
      {:error, {:snapshot_restore_failed, error}, state}
  end

  defp read_state_snapshots(%{snapshots_reader: reader}) when is_function(reader, 0),
    do: reader.()

  defp read_state_snapshots(state) do
    StatefulAlertRuleState
    |> Ash.Query.for_read(:read, %{})
    |> Ash.read(state.ash_opts)
    |> case do
      {:ok, %Keyset{results: results}} -> {:ok, results}
      {:ok, results} when is_list(results) -> {:ok, results}
      {:error, _} = error -> error
    end
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
      current_bucket_start: Bucketing.to_bucket_start(snapshot.current_bucket_start),
      bucket_counts: Bucketing.normalize_bucket_counts(snapshot.bucket_counts || %{}),
      last_seen_at: snapshot.last_seen_at,
      last_fired_at: snapshot.last_fired_at,
      last_notification_at: snapshot.last_notification_at,
      cooldown_until: snapshot.cooldown_until,
      alert_id: snapshot.alert_id,
      first_seen_at: snapshot.last_seen_at,
      diagnostics: Diagnostics.empty_diagnostics()
    }
  end
end
