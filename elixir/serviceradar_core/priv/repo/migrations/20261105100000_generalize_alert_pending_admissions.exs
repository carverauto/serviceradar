defmodule ServiceRadar.Repo.Migrations.GeneralizeAlertPendingAdmissions do
  @moduledoc """
  Generalizes `lifecycle_pending_admissions` into `alert_pending_admissions`,
  the durable backlog of every EventWriter occurrence whose alert admission has
  not committed.

  A row belongs to one lane. `lifecycle` rows keep their per-(class, series)
  FIFO and are inserted with their lifecycle event, as before. `event` and
  `metric` rows hold occurrences a refused admission deferred, or that arrived
  while their lane held a backlog; each of those lanes is one FIFO by `seq`,
  and its rows carry no series. Every row's `occurrence` stays the immutable
  snapshot alert evaluation receives.

  `down/0` refuses while a deferred `event` or `metric` row is pending, because
  the earlier table has no place for it.
  """
  use Ecto.Migration

  def up do
    schema = prefix() || "platform"

    execute(
      "ALTER TABLE #{schema}.lifecycle_pending_admissions RENAME TO alert_pending_admissions"
    )

    execute("""
    ALTER TABLE #{schema}.alert_pending_admissions
      RENAME CONSTRAINT lifecycle_pending_admissions_pkey TO alert_pending_admissions_pkey
    """)

    execute("""
    ALTER SEQUENCE #{schema}.lifecycle_pending_admissions_seq_seq
      RENAME TO alert_pending_admissions_seq_seq
    """)

    execute("""
    ALTER INDEX #{schema}.lifecycle_pending_admissions_event_id_idx
      RENAME TO alert_pending_admissions_event_id_idx
    """)

    execute("DROP INDEX IF EXISTS #{schema}.lifecycle_pending_admissions_series_seq_idx")

    execute("""
    ALTER TABLE #{schema}.alert_pending_admissions
      ADD COLUMN lane TEXT NOT NULL DEFAULT 'lifecycle',
      ALTER COLUMN class_uid DROP NOT NULL,
      ALTER COLUMN series_key DROP NOT NULL
    """)

    execute("ALTER TABLE #{schema}.alert_pending_admissions ALTER COLUMN lane DROP DEFAULT")

    execute("""
    ALTER TABLE #{schema}.alert_pending_admissions
      ADD CONSTRAINT alert_pending_admissions_lane_check
        CHECK (lane IN ('lifecycle', 'event', 'metric')),
      ADD CONSTRAINT alert_pending_admissions_series_check
        CHECK ((lane = 'lifecycle') = (class_uid IS NOT NULL AND series_key IS NOT NULL))
    """)

    execute("""
    CREATE UNIQUE INDEX alert_pending_admissions_lane_series_seq_idx
      ON #{schema}.alert_pending_admissions (lane, class_uid, series_key, seq)
    """)

    # A deferred lane is read head first by `seq`; its rows carry no series.
    execute("""
    CREATE INDEX alert_pending_admissions_lane_seq_idx
      ON #{schema}.alert_pending_admissions (lane, seq)
    """)
  end

  def down do
    schema = prefix() || "platform"

    execute("""
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM #{schema}.alert_pending_admissions WHERE lane <> 'lifecycle') THEN
        RAISE EXCEPTION 'alert_pending_admissions holds deferred event or metric admissions';
      END IF;
    END
    $$
    """)

    execute("DROP INDEX IF EXISTS #{schema}.alert_pending_admissions_lane_seq_idx")
    execute("DROP INDEX IF EXISTS #{schema}.alert_pending_admissions_lane_series_seq_idx")

    execute("""
    ALTER TABLE #{schema}.alert_pending_admissions
      DROP CONSTRAINT alert_pending_admissions_series_check,
      DROP CONSTRAINT alert_pending_admissions_lane_check,
      DROP COLUMN lane,
      ALTER COLUMN class_uid SET NOT NULL,
      ALTER COLUMN series_key SET NOT NULL
    """)

    execute("""
    CREATE UNIQUE INDEX lifecycle_pending_admissions_series_seq_idx
      ON #{schema}.alert_pending_admissions (class_uid, series_key, seq)
    """)

    execute("""
    ALTER INDEX #{schema}.alert_pending_admissions_event_id_idx
      RENAME TO lifecycle_pending_admissions_event_id_idx
    """)

    execute("""
    ALTER SEQUENCE #{schema}.alert_pending_admissions_seq_seq
      RENAME TO lifecycle_pending_admissions_seq_seq
    """)

    execute("""
    ALTER TABLE #{schema}.alert_pending_admissions
      RENAME CONSTRAINT alert_pending_admissions_pkey TO lifecycle_pending_admissions_pkey
    """)

    execute(
      "ALTER TABLE #{schema}.alert_pending_admissions RENAME TO lifecycle_pending_admissions"
    )
  end
end
