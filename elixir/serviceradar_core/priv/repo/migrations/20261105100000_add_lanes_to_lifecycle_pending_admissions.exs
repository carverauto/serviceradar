defmodule ServiceRadar.Repo.Migrations.AddLanesToLifecyclePendingAdmissions do
  @moduledoc """
  Generalizes `lifecycle_pending_admissions` into the durable backlog of every
  EventWriter occurrence whose alert admission has not committed.

  A row belongs to one lane. `lifecycle` rows keep their per-(class, series)
  FIFO and are inserted with their lifecycle event, as before. `event` and
  `metric` rows hold occurrences that a refused admission deferred, or that
  arrived while their lane held a backlog; each of those lanes is one FIFO by
  `seq`, and its rows carry no series. Every row's `occurrence` stays the
  immutable snapshot alert evaluation receives.

  The change is additive so that it is safe during a rolling upgrade. Core
  runs this migration in the first new pod while pods of the previous release
  keep running, and those pods insert, read, delete and drain lifecycle rows
  by the table's existing name and columns. The table, its constraints, its
  identity sequence and its indexes therefore keep their names, and `lane`
  defaults to `lifecycle`, so an insert that does not name the lane still
  lands in the lifecycle lane and satisfies the series check. Deferred rows
  have no series, so the previous release's series lookups never select them;
  its drain pages past them as one empty series.
  Renaming the table to match its wider role is a follow-up for a release after
  every installation has upgraded past this one.

  `down/0` refuses while a deferred `event` or `metric` row is pending, because
  the earlier table has no place for it.
  """
  use Ecto.Migration

  @table "lifecycle_pending_admissions"

  def up do
    schema = prefix() || "platform"

    execute("""
    ALTER TABLE #{schema}.#{@table}
      ADD COLUMN IF NOT EXISTS lane TEXT NOT NULL DEFAULT 'lifecycle',
      ALTER COLUMN class_uid DROP NOT NULL,
      ALTER COLUMN series_key DROP NOT NULL
    """)

    execute("""
    ALTER TABLE #{schema}.#{@table}
      ADD CONSTRAINT lifecycle_pending_admissions_lane_check
        CHECK (lane IN ('lifecycle', 'event', 'metric')),
      ADD CONSTRAINT lifecycle_pending_admissions_series_check
        CHECK ((lane = 'lifecycle') = (class_uid IS NOT NULL AND series_key IS NOT NULL))
    """)

    # A deferred lane is read head first by `seq`; its rows carry no series.
    execute("""
    CREATE INDEX IF NOT EXISTS lifecycle_pending_admissions_lane_seq_idx
      ON #{schema}.#{@table} (lane, seq)
    """)
  end

  def down do
    schema = prefix() || "platform"

    execute("""
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM #{schema}.#{@table} WHERE lane <> 'lifecycle') THEN
        RAISE EXCEPTION 'lifecycle_pending_admissions holds deferred event or metric admissions';
      END IF;
    END
    $$
    """)

    execute("DROP INDEX IF EXISTS #{schema}.lifecycle_pending_admissions_lane_seq_idx")

    execute("""
    ALTER TABLE #{schema}.#{@table}
      DROP CONSTRAINT IF EXISTS lifecycle_pending_admissions_series_check,
      DROP CONSTRAINT IF EXISTS lifecycle_pending_admissions_lane_check,
      DROP COLUMN IF EXISTS lane,
      ALTER COLUMN class_uid SET NOT NULL,
      ALTER COLUMN series_key SET NOT NULL
    """)
  end
end
