defmodule ServiceRadar.SweepJobs.LeaseMisses do
  @moduledoc """
  Marks a scheduled sweep slot missed once its collection window has been
  closed, with grace, and nothing has committed for it.

  The grace is 300 seconds. That is the sweep monitor's missed-sweep grace
  (`ServiceRadar.SweepJobs.SweepMonitorWorker`) and the same length as the
  edge-record clock tolerance. A batch that commits inside that skew is not
  missed.

  Slot end is `collection_expires`. A commit is a row in
  `platform.edge_sweep_batch_slots` for the slot id, or a
  `sweep_group_executions` row under that same id. Either one leaves the
  slot scheduled. The mark locks those due slot rows, then a later statement
  marks only the locked rows that still have no batch and no execution. A
  batch insert takes that same slot lock before its row commits, so a commit
  that landed while the lock was waiting is visible to the later statement.

  Core does not store the agent's own lease-exhausted flag. While the
  assignment is still active and a later slot is scheduled, the closed slot
  is `missed_offline`: the lease continued and this slot did not commit.
  Every other closed slot is `missed_exhausted`: the horizon was not
  extended past it, or the assignment was no longer active. A pass refills
  the horizon before it marks, so an active lease that still has future
  slots reports offline for the slot it skipped.

  A batch that commits later reopens the slot. That happens in
  `ServiceRadar.Edge.SweepProjection`, because a record is judged by its
  event time. A dropped slot is not marked and is not reopened.
  """

  alias ServiceRadar.Repo

  require Logger

  @grace_seconds 300

  @type counts :: %{missed_offline: non_neg_integer(), missed_exhausted: non_neg_integer()}

  @mark_sql """
  UPDATE platform.sweep_execution_slots AS slot
  SET
    state = CASE
      WHEN assignment.state = 'active' AND EXISTS (
        SELECT 1
        FROM platform.sweep_execution_slots AS later
        WHERE later.producer_assignment_id = slot.producer_assignment_id
          AND later.state = 'scheduled'
          AND later.slot_start > slot.slot_start
      ) THEN 'missed_offline'
      ELSE 'missed_exhausted'
    END,
    updated_at = $1
  FROM platform.sweep_producer_assignments AS assignment
  WHERE assignment.id = slot.producer_assignment_id
    AND slot.state = 'scheduled'
    AND slot.collection_expires <= $2
    AND slot.id = ANY($3::uuid[])
    AND NOT EXISTS (
      SELECT 1
      FROM platform.edge_sweep_batch_slots AS batch
      WHERE batch.execution_id = slot.id
    )
    AND NOT EXISTS (
      SELECT 1
      FROM platform.sweep_group_executions AS execution
      WHERE execution.id = slot.id
    )
  RETURNING slot.state
  """

  @lock_sql """
  SELECT slot.id
  FROM platform.sweep_execution_slots AS slot
  WHERE slot.state = 'scheduled'
    AND slot.collection_expires <= $1
  ORDER BY slot.id
  FOR UPDATE
  """

  @doc "Seconds after `collection_expires` before a slot with no commit is missed."
  @spec grace_seconds() :: pos_integer()
  def grace_seconds, do: @grace_seconds

  @doc """
  Marks every scheduled slot whose collection window closed before `now` by
  `grace_seconds/0` and that has no committed batch and no sweep execution.

  Returns how many slots moved to each missed state.
  """
  @spec mark(DateTime.t()) :: {:ok, counts()} | {:error, term()}
  def mark(%DateTime{} = now) do
    cutoff = DateTime.shift(now, second: -@grace_seconds)

    Repo.transaction(fn ->
      with {:ok, ids} <- lock_due_slot_ids(cutoff),
           {:ok, rows} <- mark_locked_slots(now, cutoff, ids) do
        tally(rows)
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp lock_due_slot_ids(cutoff) do
    case Repo.query(@lock_sql, [cutoff]) do
      {:ok, %{rows: rows}} -> {:ok, Enum.map(rows, fn [id] -> id end)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp mark_locked_slots(_now, _cutoff, []), do: {:ok, []}

  defp mark_locked_slots(now, cutoff, ids) do
    case Repo.query(@mark_sql, [now, cutoff, ids]) do
      {:ok, %{rows: rows}} -> {:ok, rows}
      {:error, reason} -> {:error, reason}
    end
  end

  defp tally(rows) do
    Enum.reduce(rows, %{missed_offline: 0, missed_exhausted: 0}, fn
      ["missed_offline"], acc ->
        Map.update!(acc, :missed_offline, &(&1 + 1))

      ["missed_exhausted"], acc ->
        Map.update!(acc, :missed_exhausted, &(&1 + 1))

      [state], acc ->
        Logger.warning("Sweep lease miss mark returned an unexpected state", state: state)
        acc
    end)
  end
end
