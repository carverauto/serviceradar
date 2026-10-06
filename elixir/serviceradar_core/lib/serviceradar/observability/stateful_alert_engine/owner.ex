defmodule ServiceRadar.Observability.StatefulAlertEngine.Owner do
  @moduledoc """
  Evaluates one committed rule input under a PostgreSQL transaction fence.

  Ownership lasts exactly as long as the database transaction. A disconnected
  or timed-out owner cannot commit after a replacement acquires the fence.
  The disposable ETS working copy is always discarded, including on rollback.
  """

  alias ServiceRadar.Monitoring.Alert
  alias ServiceRadar.Observability.AdvisoryLocks
  alias ServiceRadar.Observability.AlertEvaluationLane, as: Lane
  alias ServiceRadar.Observability.AlertEvaluationReceipt, as: Receipt
  alias ServiceRadar.Observability.AlertEvaluationWork, as: Work
  alias ServiceRadar.Observability.StatefulAlertEngine.AlertLifecycle
  alias ServiceRadar.Observability.StatefulAlertEngine.Bucketing
  alias ServiceRadar.Observability.StatefulAlertEngine.Diagnostics
  alias ServiceRadar.Observability.StatefulAlertEngine.Inbox
  alias ServiceRadar.Observability.StatefulAlertEngine.Input
  alias ServiceRadar.Observability.StatefulAlertEngine.RuntimeMetrics
  alias ServiceRadar.Observability.StatefulAlertEngine.StateMachine
  alias ServiceRadar.Observability.StatefulAlertRule
  alias ServiceRadar.Observability.StatefulAlertRuleState
  alias ServiceRadar.Repo

  require Ash.Query

  @owner_timeout_ms 15_000

  def advance(rule_id) do
    started = System.monotonic_time(:millisecond)

    result =
      Inbox.transact(@owner_timeout_ms, fn ->
        case AdvisoryLocks.try_acquire_ordered([Inbox.evaluation_key(rule_id)]) do
          :ok -> advance_owned(rule_id)
          {:error, {:advisory_locks_busy, _}} -> :busy
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    case result do
      {:ok, {:processed, disposition, measurements}} ->
        RuntimeMetrics.completion(
          disposition,
          Map.put(
            measurements,
            :execution_ms,
            max(System.monotonic_time(:millisecond) - started, 0)
          )
        )

        {:ok, {:processed, disposition}}

      other ->
        other
    end
  end

  def defer(rule_id, work_id, reason) do
    Inbox.transact(2_000, fn ->
      case AdvisoryLocks.try_acquire_ordered([Inbox.evaluation_key(rule_id)]) do
        :ok ->
          case Ash.get(Work, work_id, actor: Inbox.actor()) do
            {:ok, %{rule_id: ^rule_id} = work} ->
              seconds = min(Integer.pow(2, min(work.attempts + 1, 8)), 300)

              work
              |> Ash.Changeset.for_update(
                :retry,
                %{
                  attempts: work.attempts + 1,
                  available_at: DateTime.shift(DateTime.utc_now(), second: seconds),
                  last_error: String.slice(inspect(reason), 0, 2_048)
                },
                actor: Inbox.actor()
              )
              |> Ash.update!()

              :ok

            _ ->
              :ok
          end

        {:error, {:advisory_locks_busy, _}} ->
          :busy

        {:error, error} ->
          Repo.rollback(error)
      end
    end)
  end

  @doc "Removes an expired snapshot only after rechecking it under the evaluator fence."
  def cleanup_snapshot(rule_id, snapshot_id, cutoff) do
    Inbox.transact(2_000, fn ->
      # Admission can otherwise insert new work between our empty-inbox read
      # and deleting the snapshot that input needs. Match the relation/mutex
      # ordering used by admission and the raw replay trigger.
      Inbox.lock_admission()

      case AdvisoryLocks.try_acquire_ordered([Inbox.evaluation_key(rule_id)]) do
        :ok -> cleanup_owned(rule_id, snapshot_id, cutoff)
        {:error, {:advisory_locks_busy, _}} -> :kept
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp cleanup_owned(rule_id, snapshot_id, cutoff) do
    case Ash.get(StatefulAlertRuleState, snapshot_id, actor: Inbox.actor()) do
      {:ok, %{rule_id: ^rule_id} = snapshot} ->
        stale? = is_nil(snapshot.last_seen_at) or DateTime.before?(snapshot.last_seen_at, cutoff)

        cooled? =
          is_nil(snapshot.cooldown_until) or
            DateTime.before?(snapshot.cooldown_until, DateTime.utc_now())

        # Pending accepted work needs this authoritative state even if the
        # source timestamp is old. An open incident must retain its identity.
        if stale? and cooled? and is_nil(oldest(rule_id)) and terminal_alert?(snapshot.alert_id) do
          Ash.destroy!(snapshot, actor: Inbox.actor())
          :deleted
        else
          :kept
        end

      {:ok, nil} ->
        :kept

      {:ok, _other_rule} ->
        :kept

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp terminal_alert?(nil), do: true

  defp terminal_alert?(alert_id) do
    case Ash.get(Alert, alert_id, actor: Inbox.actor()) do
      {:ok, %{status: :resolved}} -> true
      {:ok, nil} -> true
      {:ok, _open} -> false
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp advance_owned(rule_id) do
    now = DateTime.utc_now()

    case oldest(rule_id) do
      nil ->
        :empty

      work ->
        if DateTime.after?(work.available_at, now) do
          {:backoff, max(DateTime.diff(work.available_at, now, :second), 1)}
        else
          evaluate(work)
        end
    end
  end

  defp oldest(rule_id) do
    Work
    |> Ash.Query.filter(rule_id == ^rule_id)
    |> Ash.Query.sort(position: :asc)
    |> Ash.Query.limit(1)
    |> Ash.read!(actor: Inbox.actor())
    |> List.first()
  end

  defp evaluate(work) do
    work =
      Map.put(
        work,
        :queue_wait_ms,
        max(DateTime.diff(DateTime.utc_now(), work.accepted_at, :millisecond), 0)
      )

    active =
      StatefulAlertRule
      |> Ash.Query.filter(id == ^work.rule_id and enabled == true)
      |> Ash.Query.select([:id])
      |> Ash.read!(actor: Inbox.actor())

    lane = Ash.get!(Lane, work.rule_id, actor: Inbox.actor())

    if active == [] or work.position <= lane.cancelled_through do
      complete(work, :cancelled, %{reason: "rule_disabled_or_deleted"}, 0)
    else
      if work.signal == :maintenance, do: evaluate_maintenance(work), else: evaluate_active(work)
    end
  rescue
    error -> Repo.rollback({:evaluation_failed, work.id, error})
  end

  defp evaluate_active(work) do
    case Input.decode(work) do
      {:ok, rule, record} -> evaluate_decoded(work, rule, record)
      {:error, reason} -> complete(work, :failed, %{reason: Atom.to_string(reason)}, 0)
    end
  end

  defp evaluate_maintenance(work) do
    case decode_maintenance(work) do
      {:ok, rule, cutoff, now, live_series_keys} ->
        table = :ets.new(:alert_evaluation_working_state, [:set, :private])

        try do
          restore(table, rule.id)
          state = %{table: table, ash_opts: [actor: Inbox.actor()], transactional?: true}
          count = StateMachine.sweep_stale_anomalies(rule, cutoff, now, state, live_series_keys)

          case count do
            {:error, reason} ->
              Repo.rollback({:evaluation_failed, work.id, reason})

            count when is_integer(count) ->
              flush_changed(table, rule, state, work.id)
              complete(work, :completed, %{}, count)
          end
        after
          :ets.delete(table)
        end

      {:error, reason} ->
        complete(work, :failed, %{reason: Atom.to_string(reason)}, 0)
    end
  end

  defp decode_maintenance(work) do
    rule = Input.restore_rule(work.rule_revision)

    with true <- rule.id == work.rule_id,
         {:ok, cutoff, _} <- DateTime.from_iso8601(work.payload["cutoff"]),
         {:ok, now, _} <- DateTime.from_iso8601(work.payload["now"]),
         series when is_list(series) <- work.payload["live_series_keys"],
         true <- Enum.all?(series, &is_binary/1) do
      {:ok, rule, cutoff, now, MapSet.new(series)}
    else
      _ -> {:error, :invalid_accepted_maintenance}
    end
  rescue
    _ -> {:error, :invalid_accepted_maintenance}
  end

  defp evaluate_decoded(work, rule, record) do
    table = :ets.new(:alert_evaluation_working_state, [:set, :private])

    try do
      restore(table, rule.id)
      state = %{table: table, ash_opts: [actor: Inbox.actor()], transactional?: true}

      result =
        case work.signal do
          :log -> StateMachine.process_log_rules(record, [rule], state)
          :event -> StateMachine.process_event_rules(record, [rule], state)
          :metric -> StateMachine.process_metric_rules(record, [rule], state)
        end

      require_ok(result, work.id)
      flush_changed(table, rule, state, work.id)
      complete(work, :completed, %{}, 0)
    after
      :ets.delete(table)
    end
  end

  defp restore(table, rule_id) do
    StatefulAlertRuleState
    |> Ash.Query.for_read(:by_rule, %{rule_id: rule_id})
    |> Ash.read!(actor: Inbox.actor())
    |> Enum.each(fn row -> :ets.insert(table, {{rule_id, row.group_key}, normalize(row)}) end)
  end

  defp normalize(row) do
    %{
      rule_id: row.rule_id,
      group_key: row.group_key,
      group_values: row.group_values || %{},
      window_seconds: row.window_seconds,
      bucket_seconds: row.bucket_seconds,
      current_bucket_start: Bucketing.to_bucket_start(row.current_bucket_start),
      bucket_counts: Bucketing.normalize_bucket_counts(row.bucket_counts || %{}),
      last_seen_at: row.last_seen_at,
      last_fired_at: row.last_fired_at,
      last_notification_at: row.last_notification_at,
      cooldown_until: row.cooldown_until,
      alert_id: row.alert_id,
      first_seen_at: row.first_seen_at || row.last_seen_at,
      diagnostics:
        if(row.diagnostics in [nil, %{}],
          do: Diagnostics.empty_diagnostics(),
          else: row.diagnostics
        ),
      flush_required: false
    }
  end

  defp flush_changed(table, rule, state, work_id) do
    :ets.foldl(
      fn {_key, snapshot}, :ok ->
        if snapshot.flush_required do
          require_ok(AlertLifecycle.persist_snapshot(snapshot, rule, state), work_id)
        end

        :ok
      end,
      :ok,
      table
    )
  end

  defp complete(work, disposition, details, resolved_count) do
    Receipt
    |> Ash.Changeset.for_create(
      :record,
      %{
        rule_id: work.rule_id,
        source_key: work.source_key,
        position: work.position,
        disposition: disposition,
        details: details,
        resolved_count: resolved_count
      },
      actor: Inbox.actor()
    )
    |> Ash.create!()

    Ash.destroy!(work, actor: Inbox.actor())
    {:processed, disposition, %{signal: work.signal, queue_wait_ms: work.queue_wait_ms}}
  end

  defp require_ok(:ok, _work_id), do: :ok

  defp require_ok(:error, work_id),
    do: Repo.rollback({:evaluation_failed, work_id, :snapshot_persistence_failed})

  defp require_ok({:error, reason}, work_id),
    do: Repo.rollback({:evaluation_failed, work_id, reason})
end
