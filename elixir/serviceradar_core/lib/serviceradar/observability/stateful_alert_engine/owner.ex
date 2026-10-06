defmodule ServiceRadar.Observability.StatefulAlertEngine.Owner do
  @moduledoc """
  Evaluates one committed rule input under a PostgreSQL transaction fence.

  Ownership lasts exactly as long as the database transaction. A disconnected
  or timed-out owner cannot commit after a replacement acquires the fence.
  The disposable ETS working copy is always discarded, including on rollback.
  """

  alias ServiceRadar.Observability.AdvisoryLocks
  alias ServiceRadar.Observability.AlertEvaluationLane, as: Lane
  alias ServiceRadar.Observability.AlertEvaluationReceipt, as: Receipt
  alias ServiceRadar.Observability.AlertEvaluationWork, as: Work
  alias ServiceRadar.Observability.StatefulAlertEngine.AlertLifecycle
  alias ServiceRadar.Observability.StatefulAlertEngine.Bucketing
  alias ServiceRadar.Observability.StatefulAlertEngine.Diagnostics
  alias ServiceRadar.Observability.StatefulAlertEngine.Inbox
  alias ServiceRadar.Observability.StatefulAlertEngine.Input
  alias ServiceRadar.Observability.StatefulAlertEngine.StateMachine
  alias ServiceRadar.Observability.StatefulAlertRule
  alias ServiceRadar.Observability.StatefulAlertRuleState
  alias ServiceRadar.Repo

  require Ash.Query

  @owner_timeout_ms 15_000

  def advance(rule_id) do
    Inbox.transact(@owner_timeout_ms, fn ->
      case AdvisoryLocks.try_acquire_ordered([Inbox.evaluation_key(rule_id)]) do
        :ok -> advance_owned(rule_id)
        {:error, {:advisory_locks_busy, _}} -> :busy
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
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
    active =
      StatefulAlertRule
      |> Ash.Query.filter(id == ^work.rule_id and enabled == true)
      |> Ash.Query.select([:id])
      |> Ash.read!(actor: Inbox.actor())

    lane = Ash.get!(Lane, work.rule_id, actor: Inbox.actor())

    if active == [] or work.position <= lane.cancelled_through do
      complete(work, :cancelled, %{reason: "rule_disabled_or_deleted"}, 0)
    else
      evaluate_active(work)
    end
  rescue
    error -> Repo.rollback({:evaluation_failed, work.id, error})
  end

  defp evaluate_active(work) do
    rule = Input.restore_rule(work.rule_revision)
    table = :ets.new(:alert_evaluation_working_state, [:set, :private])

    try do
      restore(table, rule.id)
      state = %{table: table, ash_opts: [actor: Inbox.actor()], transactional?: true}
      record = Input.restore_record(work.payload)

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
    {:processed, disposition}
  end

  defp require_ok(:ok, _work_id), do: :ok

  defp require_ok(:error, work_id),
    do: Repo.rollback({:evaluation_failed, work_id, :snapshot_persistence_failed})

  defp require_ok({:error, reason}, work_id),
    do: Repo.rollback({:evaluation_failed, work_id, reason})
end
