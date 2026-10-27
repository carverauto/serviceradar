defmodule ServiceRadar.Observability.StatefulAlertEngine.Inbox do
  @moduledoc """
  Bounded, all-or-nothing durable admission for stateful alert evaluation.

  The admission mutex only covers capacity, replay lookup and committed input
  order. Evaluators use a different fence and never acquire this mutex, so a
  slow rule cannot delay admission for another rule. Accepted rows have no TTL.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Ash.Page
  alias ServiceRadar.Observability.AdvisoryLocks
  alias ServiceRadar.Observability.AlertEvaluationLane, as: Lane
  alias ServiceRadar.Observability.AlertEvaluationReceipt, as: Receipt
  alias ServiceRadar.Observability.AlertEvaluationWork, as: Work
  alias ServiceRadar.Observability.StatefulAlertEngine.EvaluationWorker
  alias ServiceRadar.Observability.StatefulAlertEngine.Input
  alias ServiceRadar.Observability.StatefulAlertEngine.Record
  alias ServiceRadar.Observability.StatefulAlertEngine.Rollout
  alias ServiceRadar.Observability.StatefulAlertEngine.RuleMatcher
  alias ServiceRadar.Observability.StatefulAlertEngine.RuntimeMetrics
  alias ServiceRadar.Observability.StatefulAlertRule
  alias ServiceRadar.Repo

  require Ash.Query
  require Logger

  @defaults %{
    admission_timeout_ms: 2_000,
    batch_records: 500,
    batch_work: 5_000,
    pending_count: 50_000,
    pending_bytes: 64 * 1_024 * 1_024,
    rule_count: 5_000,
    rule_bytes: 8 * 1_024 * 1_024
  }
  @admission_key "alert-evaluation:admission:v1"
  @client_backstop_multiplier 10
  @min_client_timeout_ms 10_000
  @pending_notifications {__MODULE__, :pending_notifications}

  @doc "Commits every eligible rule occurrence or rejects the entire batch."
  def admit(signal, records) when signal in [:log, :event, :metric] and is_list(records) do
    started = System.monotonic_time(:millisecond)

    case admit_batch(signal, records) do
      {:ok, {keys, admitted}} ->
        RuntimeMetrics.admission(signal, {:ok, keys, admitted}, started)
        {:ok, keys}

      {:error, _} = error ->
        RuntimeMetrics.admission(signal, error, started)
        error
    end
  end

  def admit(_signal, _records), do: {:error, :invalid_payload}

  defp admit_batch(signal, records) do
    limits = limits()

    with :ok <- Rollout.admission_ready(),
         :ok <- within(length(records), limits.batch_records, :batch_records),
         {:ok, prepared} <- prepare(signal, records) do
      transact(
        limits.admission_timeout_ms,
        fn ->
          lock_admission()
          rules = active_rules(signal, limits.batch_work)
          require_ok(within(length(rules), limits.batch_work, :rule_inventory))
          candidates = candidates(rules, prepared, limits.batch_work)
          commit_candidates(candidates, signal, limits)
        end,
        caller: {__MODULE__, :admit},
        telemetry_options: [signal: signal]
      )
    end
  end

  @doc "Appends a stale-resolution ordering barrier behind all previously accepted rule input."
  def admit_maintenance(rule_name, cutoff, now, live_series_keys) do
    with :ok <- Rollout.admission_ready(),
         {:ok, {keys, _admitted}} <-
           admit_maintenance_ready(rule_name, cutoff, now, live_series_keys) do
      {:ok, keys}
    end
  end

  defp admit_maintenance_ready(rule_name, cutoff, now, live_series_keys) do
    limits = limits()
    source_key = "maintenance:" <> Ash.UUID.generate()
    payload = %{cutoff: cutoff, now: now, live_series_keys: MapSet.to_list(live_series_keys)}
    json = Jason.encode!(payload)
    payload = Jason.decode!(json)

    transact(
      limits.admission_timeout_ms,
      fn ->
        lock_admission()

        rules =
          StatefulAlertRule
          |> Ash.Query.for_read(:active, %{})
          |> Ash.Query.filter(name == ^rule_name)
          |> Ash.read!(actor: actor())
          |> Page.unwrap!()

        candidates =
          Enum.map(rules, fn rule ->
            revision = Input.revision(rule)

            %{
              rule_id: rule.id,
              source_key: source_key,
              rule_revision: revision,
              payload: payload,
              payload_bytes: byte_size(json) + byte_size(Jason.encode!(revision))
            }
          end)

        commit_candidates(candidates, :maintenance, limits)
      end,
      caller: {__MODULE__, :admit_maintenance}
    )
  rescue
    error -> {:error, {:invalid_payload, error}}
  end

  @doc false
  def lock_admission do
    # TRUNCATE takes its relation lock before its trigger runs. Match that
    # acquisition order to avoid a relation/advisory lock inversion.
    Repo.query!("LOCK TABLE platform.stateful_alert_rules IN ACCESS SHARE MODE")
    require_ok(AdvisoryLocks.acquire_ordered([{:exclusive, @admission_key}]))
  end

  defp commit_candidates(candidates, signal, limits) do
    require_ok(within(length(candidates), limits.batch_work, :batch_work))
    pending = reject_replays(candidates)
    require_capacity(pending, limits)
    insert(pending, signal)

    pending
    |> Enum.map(& &1.rule_id)
    |> Enum.uniq()
    |> Enum.each(&enqueue_hint/1)

    {Enum.map(candidates, &{&1.rule_id, &1.source_key}), length(pending)}
  end

  # Hints commit with the source transaction, but a failed hint insert must
  # not poison that transaction or discard the authoritative accepted work.
  defp enqueue_hint(rule_id) do
    Repo.query!("SAVEPOINT alert_evaluation_hint")

    result =
      try do
        insert_hint(rule_id)
      rescue
        error -> {:error, error}
      catch
        kind, reason -> {:error, {kind, reason}}
      end

    case result do
      {:ok, _job} ->
        Repo.query!("RELEASE SAVEPOINT alert_evaluation_hint")

      {:error, _reason} ->
        Repo.query!("ROLLBACK TO SAVEPOINT alert_evaluation_hint")
        Repo.query!("RELEASE SAVEPOINT alert_evaluation_hint")
        RuntimeMetrics.store_failure()
        Logger.warning("Alert evaluation wake-up deferred to durable recovery")
    end

    :ok
  end

  # Admission is serialized by the short admission mutex. Coalesce wake-ups
  # here without Oban's unique-insert nested transaction: its exception path
  # marks the enclosing DBConnection transaction failed even after a SQL
  # savepoint rollback. Bulk insertion uses Oban's public API and stays inside
  # our savepoint. A racing recovery hint is harmless under the owner fence.
  defp insert_hint(rule_id) do
    worker = Oban.Worker.to_string(EvaluationWorker)

    case Repo.query!(
           "SELECT id FROM platform.oban_jobs WHERE worker = $1 AND args->>'rule_id' = $2 " <>
             "AND state IN ('available', 'scheduled', 'retryable') LIMIT 1",
           [worker, rule_id]
         ) do
      %{rows: [[_id]]} ->
        {:ok, :already_scheduled}

      %{rows: []} ->
        case Oban.insert_all([EvaluationWorker.new(%{"rule_id" => rule_id})]) do
          [job] -> {:ok, job}
          other -> {:error, {:evaluation_hint_insert, other}}
        end
    end
  end

  @doc "Configured admission bounds; these apply to retries and direct callers alike."
  def limits do
    configured = Application.get_env(:serviceradar_core, :alert_evaluation_limits, [])

    Map.new(@defaults, fn {key, default} ->
      case Keyword.get(configured, key, default) do
        value when is_integer(value) and value > 0 -> {key, value}
        _ -> raise ArgumentError, "alert evaluation #{key} must be positive"
      end
    end)
  end

  def actor, do: SystemActor.system(:alert_engine)

  def evaluation_key(rule_id), do: "alert-evaluation:owner:v1:#{rule_id}"

  @doc """
  Sends Ash notifications once the outermost notification queue commits, and
  drops them if that transaction rolls back. With no queue open, sends them now.

  `transact/2` owns the queue. A caller that opens its own `Repo.transaction`
  owns the same queue by wrapping that transaction in `with_notification_queue/1`.
  A nested call appends to the queue already open, so a savepoint commit does
  not send before the outermost transaction commits.

  An Ash action run inside a plain `Repo.transaction` cannot send its own
  notifications: Ash holds them back and logs them as missed. Actions here run
  with `return_notifications?: true` and pass the result to this function.
  """
  @spec notify_after_commit([Ash.Notifier.Notification.t()]) :: :ok
  def notify_after_commit(notifications) when is_list(notifications) do
    case Process.get(@pending_notifications) do
      nil -> _ = Ash.Notifier.notify(notifications)
      pending -> Process.put(@pending_notifications, [notifications | pending])
    end

    :ok
  end

  @doc """
  Owns the notification queue around one transaction result.

  The outermost call sends what `notify_after_commit/1` queued only when `work`
  returns `{:ok, _}`. Any other result, including a rollback, drops the queue.
  A call nested inside an open queue, including `transact/2`, leaves sending to
  that outer owner.
  """
  @spec with_notification_queue((-> result)) :: result when result: term()
  def with_notification_queue(work) when is_function(work, 0) do
    if Process.get(@pending_notifications) do
      work.()
    else
      Process.put(@pending_notifications, [])

      try do
        result = work.()
        pending = Process.get(@pending_notifications)

        if match?({:ok, _}, result) do
          _ = pending |> Enum.reverse() |> List.flatten() |> Ash.Notifier.notify()
        end

        result
      after
        Process.delete(@pending_notifications)
      end
    end
  end

  # PostgreSQL's lock and statement timeouts enforce `timeout` per statement: an
  # expired statement is cancelled, the transaction rolls back and the connection
  # stays usable. The client checkout deadline is per transaction and only
  # backstops a store PostgreSQL cannot reach, so size it for multiple round
  # trips with a floor for short tail polls in Completion.await/2.
  def transact(timeout, work, opts \\ []) do
    with_notification_queue(fn -> run_transaction(timeout, work, opts) end)
  end

  defp run_transaction(timeout, work, opts) do
    caller = Keyword.get(opts, :caller, {__MODULE__, :transact})
    maybe_set_process_label(caller)

    telemetry_options =
      Keyword.merge(
        [caller: caller, timeout_ms: timeout],
        Keyword.get(opts, :telemetry_options, [])
      )

    Repo.transaction(
      fn ->
        %{rows: [[lock_timeout, statement_timeout]]} =
          Repo.query!(
            "SELECT current_setting('lock_timeout'), current_setting('statement_timeout')",
            [],
            telemetry_options: telemetry_options
          )

        set_timeouts("#{timeout}ms", "#{timeout}ms", telemetry_options)
        result = work.()
        # A nested caller transaction (including a sandbox) keeps SET LOCAL
        # values until its own end. Do not leave our short budget on it.
        set_timeouts(lock_timeout, statement_timeout, telemetry_options)
        result
      end,
      timeout: client_timeout(timeout),
      telemetry_options: telemetry_options
    )
  rescue
    error -> {:error, {:store_unavailable, error}}
  catch
    :exit, reason -> {:error, {:store_unavailable, reason}}
  end

  defp client_timeout(timeout) do
    max(timeout * @client_backstop_multiplier, @min_client_timeout_ms)
  end

  defp set_timeouts(lock_timeout, statement_timeout, telemetry_options) do
    Repo.query!(
      "SELECT set_config('lock_timeout', $1, true), set_config('statement_timeout', $2, true)",
      [lock_timeout, statement_timeout],
      telemetry_options: telemetry_options
    )
  end

  defp maybe_set_process_label(caller) do
    case Process.info(self(), :registered_name) do
      {:registered_name, []} -> Process.set_label(caller)
      _ -> :ok
    end
  end

  defp prepare(signal, records) do
    records
    |> Enum.reduce_while({:ok, []}, fn record, {:ok, acc} ->
      case Input.prepare(signal, record) do
        {:ok, prepared} -> {:cont, {:ok, [prepared | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      error -> error
    end
  end

  defp active_rules(signal, limit) do
    StatefulAlertRule
    |> Ash.Query.for_read(:active, %{})
    |> Ash.Query.filter(signal == ^signal)
    |> Ash.Query.limit(limit + 1)
    |> Ash.read!(actor: actor())
    |> Page.unwrap!()
  catch
    :throw, {DBConnection, connection, reason} ->
      # Ash may roll back with its query instead of raising. Preserve the
      # transaction rollback while exposing the admission failure contract.
      throw({DBConnection, connection, {:store_unavailable, reason}})
  end

  defp candidates(rules, records, limit) do
    records = Enum.map(records, &Map.put(&1, :record, Input.restore_record(&1.payload)))

    rules
    |> Stream.flat_map(fn rule ->
      revision = Input.revision(rule)
      revision_bytes = byte_size(Jason.encode!(revision))

      records
      |> Stream.filter(&eligible?(rule, &1.record))
      |> Stream.map(fn record ->
        %{
          rule_id: rule.id,
          source_key: record.source_key,
          rule_revision: revision,
          payload: record.payload,
          payload_bytes: record.bytes + revision_bytes
        }
      end)
    end)
    |> Stream.uniq_by(&{&1.rule_id, &1.source_key})
    |> Enum.take(limit + 1)
  end

  defp eligible?(%{signal: :log} = rule, record), do: RuleMatcher.rule_matches_log?(record, rule)

  defp eligible?(%{signal: :event} = rule, record) do
    # Seasonal disposition may change severity or metadata before matching.
    # Keep those candidates; the owner runs the authoritative state machine.
    not Record.skip_engine_event?(record) and
      (RuleMatcher.anomaly_open_rule?(rule) or
         RuleMatcher.rule_matches_event?(record, rule) or
         RuleMatcher.rule_recovers_event?(record, rule))
  end

  defp eligible?(%{signal: :metric} = rule, record),
    do: RuleMatcher.rule_matches_metric?(record, rule)

  defp reject_replays([]), do: []

  defp reject_replays(candidates) do
    rule_ids = candidates |> Enum.map(& &1.rule_id) |> Enum.uniq()
    source_keys = candidates |> Enum.map(& &1.source_key) |> Enum.uniq()

    recorded =
      [Work, Receipt]
      |> Enum.flat_map(fn resource ->
        resource
        |> Ash.Query.filter(rule_id in ^rule_ids and source_key in ^source_keys)
        |> Ash.Query.select([:rule_id, :source_key])
        |> Ash.read!(actor: actor())
      end)
      |> MapSet.new(&{&1.rule_id, &1.source_key})

    Enum.reject(candidates, &MapSet.member?(recorded, {&1.rule_id, &1.source_key}))
  end

  defp require_capacity([], _limits), do: :ok

  defp require_capacity(candidates, limits) do
    # Resources own the schema and writes. This single aggregate is deliberately
    # in the short admission transaction; no evaluator holds its capacity lock.
    %{rows: [[count, bytes]]} =
      Repo.query!(
        "SELECT count(*), coalesce(sum(payload_bytes), 0)::bigint FROM platform.alert_evaluation_work"
      )

    require_ok(within(count + length(candidates), limits.pending_count, :pending_count))

    require_ok(
      within(
        bytes + Enum.sum(Enum.map(candidates, & &1.payload_bytes)),
        limits.pending_bytes,
        :pending_bytes
      )
    )

    grouped = Enum.group_by(candidates, & &1.rule_id)
    rule_ids = grouped |> Map.keys() |> Enum.map(&Ecto.UUID.dump!/1)

    %{rows: rows} =
      Repo.query!(
        "SELECT rule_id, count(*), coalesce(sum(payload_bytes), 0)::bigint FROM platform.alert_evaluation_work WHERE rule_id = ANY($1::uuid[]) GROUP BY rule_id",
        [rule_ids]
      )

    existing =
      Map.new(rows, fn [raw_id, count, bytes] -> {Ecto.UUID.load!(raw_id), {count, bytes}} end)

    Enum.each(grouped, fn {rule_id, records} ->
      {count, bytes} = Map.get(existing, rule_id, {0, 0})
      require_ok(within(count + length(records), limits.rule_count, :rule_count))

      require_ok(
        within(
          bytes + Enum.sum(Enum.map(records, & &1.payload_bytes)),
          limits.rule_bytes,
          :rule_bytes
        )
      )
    end)
  end

  defp insert(candidates, signal) do
    now = DateTime.utc_now()

    params =
      candidates
      |> Enum.group_by(& &1.rule_id)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.flat_map(fn {rule_id, records} ->
        {lane, registered} =
          Lane
          |> Ash.Changeset.for_create(:register, %{rule_id: rule_id}, actor: actor())
          |> Ash.create!(return_notifications?: true)

        {_lane, reserved} =
          lane
          |> Ash.Changeset.for_update(
            :reserve,
            %{next_position: lane.next_position + length(records)},
            actor: actor()
          )
          |> Ash.update!(return_notifications?: true)

        notify_after_commit(registered ++ reserved)

        records
        |> Enum.with_index(lane.next_position + 1)
        |> Enum.map(fn {record, position} ->
          Map.merge(record, %{position: position, signal: signal, available_at: now})
        end)
      end)

    case Ash.bulk_create(params, Work, :admit,
           actor: actor(),
           return_errors?: true,
           stop_on_error?: true
         ) do
      %Ash.BulkResult{status: :success} -> :ok
      %Ash.BulkResult{errors: errors} -> Repo.rollback({:admission_failed, errors})
    end
  end

  defp within(value, limit, _dimension) when value <= limit, do: :ok
  defp within(_value, _limit, dimension), do: {:error, {:overloaded, dimension}}
  defp require_ok(:ok), do: :ok
  defp require_ok({:error, reason}), do: Repo.rollback(reason)
end
