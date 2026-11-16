defmodule ServiceRadar.Repo.Migrations.AddEdgeLateAdmissionBounds do
  @moduledoc """
  The bounds late admission needs (openspec add-edge-production-time-admission, Decision 5):

    * `edge_pipeline_settings.late_admission_max_age_seconds`: the oldest record core will
      still publish as late PRIMARY, on the global row only. NULL means the code default,
      `ServiceRadar.Edge.PipelineSettings.default_late_admission_max_age_seconds/0` (14 days).
    * `edge_ledger_coverage.complete_since`: every `event_ledger` row with `inserted_at` at or
      after it is still retained. `EdgeLedgerRetentionWorker` advances it, in the statement
      that deletes ledger rows, to that prune's cutoff; a trigger refuses to move it backward.

  The seed must be no later than any row retention may already have deleted, and no earlier
  than necessary. Every horizon the retention worker has ever applied is at least the default
  sweep-horizon ceiling of 30 days (its spool component adds a lease margin and a grant TTL on
  top, and configured ceilings only raise it), so retention has never deleted a row inserted
  after `now() - 30 days`. Seeding there is therefore safe whatever the operator configured,
  and it costs nothing: a record older than that is past the 14-day late window and is AUDIT
  regardless. A database built from a schema-only baseline has no seed row; it has never
  pruned, so its ledger is complete since creation, which is what an absent row means.
  """
  use Ecto.Migration

  @settings "edge_pipeline_settings"
  @coverage "edge_ledger_coverage"

  def up do
    schema = prefix() || "platform"

    # ALTER TABLE takes ACCESS EXCLUSIVE on the small settings table. Never queue behind a
    # long transaction: fail fast and let the migration be retried.
    execute("SET LOCAL lock_timeout = '5s'")

    execute("""
    ALTER TABLE #{schema}.#{@settings}
      ADD COLUMN late_admission_max_age_seconds INTEGER,
      ADD CONSTRAINT #{@settings}_late_admission_max_age_chk
        CHECK (late_admission_max_age_seconds IS NULL
               OR (scope = 'global' AND late_admission_max_age_seconds > 0))
    """)

    execute("""
    CREATE TABLE IF NOT EXISTS #{schema}.#{@coverage} (
      id smallint PRIMARY KEY DEFAULT 1 CHECK (id = 1),
      complete_since timestamptz NOT NULL,
      updated_at timestamptz NOT NULL DEFAULT now()
    )
    """)

    execute("""
    CREATE OR REPLACE FUNCTION #{schema}.edge_ledger_coverage_monotonic()
    RETURNS trigger
    LANGUAGE plpgsql
    AS $$
    BEGIN
      IF NEW.complete_since < OLD.complete_since THEN
        RAISE EXCEPTION 'edge_ledger_coverage.complete_since never moves backward (% -> %)',
          OLD.complete_since, NEW.complete_since
          USING ERRCODE = 'check_violation';
      END IF;

      RETURN NEW;
    END;
    $$
    """)

    execute("""
    CREATE OR REPLACE TRIGGER edge_ledger_coverage_monotonic_trg
      BEFORE UPDATE ON #{schema}.#{@coverage}
      FOR EACH ROW EXECUTE FUNCTION #{schema}.edge_ledger_coverage_monotonic()
    """)

    execute("""
    INSERT INTO #{schema}.#{@coverage} (id, complete_since)
    VALUES (1, now() - interval '30 days')
    ON CONFLICT (id) DO NOTHING
    """)
  end

  def down do
    schema = prefix() || "platform"

    execute("DROP TABLE IF EXISTS #{schema}.#{@coverage}")
    execute("DROP FUNCTION IF EXISTS #{schema}.edge_ledger_coverage_monotonic()")

    execute("""
    ALTER TABLE #{schema}.#{@settings}
      DROP CONSTRAINT IF EXISTS #{@settings}_late_admission_max_age_chk,
      DROP COLUMN IF EXISTS late_admission_max_age_seconds
    """)
  end
end
