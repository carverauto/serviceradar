defmodule ServiceRadar.Repo.Migrations.AddIdentityReconciliationRuns do
  @moduledoc """
  Durable record of every scheduled identity reconciliation run.

  `DuplicateSweep.reconcile_duplicates/1` already builds a complete summary of
  each run -- duplicate identifier candidates, duplicate/mergeable/blocked
  component counts, blocked device count, merges, errors, duration -- and then
  `Logger.info`s it and drops it on the floor. `JobSchedule.run_identity_reconciliation`
  logs the same map a second time and discards it too. `report_blocked_components/1`
  computes the size of the largest ambiguous component, emits one warning line and
  a telemetry event, and returns `:ok`.

  Two consequences, both of which cost real investigation time:

    * Nobody can answer "did that run stop at its work cap" after the fact. The
      cap is normalized once at the top of the run and then consulted only inside
      the merge reduce, so the fact that a run was truncated exists nowhere --
      not in the stats map, not in telemetry, not in the log line.
    * A run that raises is rescued into `{:error, reason}` and leaves no trace at
      all beyond one `Logger.warning`. In a pod that has since restarted, that is
      no trace.

  Explaining an inventory-count drop therefore meant joining `ocsf_devices`,
  `merge_audit`, `device_revival_audit` and `device_identifiers` by hand in psql
  (GitHub #4229). This table is the piece of that investigation which could not
  be recovered from the database at all, because it was never written.

  ## Why counters and not an event stream

  One row per run, not one row per merge. Per-merge evidence already exists in
  `merge_audit`, and the per-component evidence edges are derived at query time
  from `device_identifiers` so they stay consistent with the identifiers they
  describe. Snapshotting edges here would write N rows per component per run and
  then drift from the very table it claims to explain.

  `blocked_component_devices` therefore stores component *membership* only: which
  device uids the sweep refused to merge. The reason it refused them is a live
  question, answered by walking current identifier evidence.

  ## Retention

  Pruned by the sweep itself to a configurable window (default 30 days). At the
  current cadence this table gains a few hundred rows a day; unbounded growth in
  a diagnostics table is how a diagnostic becomes an incident.
  """

  use Ecto.Migration

  @prefix "platform"

  def up do
    create table(:identity_reconciliation_runs, primary_key: false, prefix: @prefix) do
      add(:run_id, :uuid, primary_key: true)

      add(:started_at, :utc_datetime_usec, null: false)
      add(:completed_at, :utc_datetime_usec)
      add(:duration_ms, :bigint)

      # `completed` or `failed`. A rescued run is recorded, not silently absent.
      add(:status, :text, null: false)
      add(:error_summary, :text)

      add(:duplicate_identifier_count, :integer, null: false, default: 0)
      add(:duplicate_components, :integer, null: false, default: 0)
      add(:mergeable_components, :integer, null: false, default: 0)
      add(:blocked_components, :integer, null: false, default: 0)
      add(:blocked_devices, :integer, null: false, default: 0)
      add(:largest_blocked_component, :integer, null: false, default: 0)

      add(:merges, :integer, null: false, default: 0)
      add(:errors, :integer, null: false, default: 0)

      # The operational bound this run was given, and whether it was hit. Neither
      # is derivable after the fact from anything else that is persisted.
      add(:max_merges_configured, :integer)
      add(:merge_cap_reached, :boolean, null: false, default: false)

      # Membership of each ambiguous component the sweep declined to merge:
      # `[%{"device_ids" => [...]}, ...]`, capped, with a `truncated` marker when
      # the cap elides components.
      add(:blocked_component_devices, :jsonb, null: false, default: fragment("'[]'::jsonb"))

      add(:trigger, :text, null: false, default: "scheduled")
      add(:job_schedule_id, :bigint)
    end

    create(
      index(:identity_reconciliation_runs, [:started_at],
        prefix: @prefix,
        name: "identity_reconciliation_runs_started_at_idx"
      )
    )

    create(
      index(:identity_reconciliation_runs, [:status, :started_at],
        prefix: @prefix,
        name: "identity_reconciliation_runs_status_started_at_idx"
      )
    )
  end

  def down do
    drop(table(:identity_reconciliation_runs, prefix: @prefix))
  end
end
