defmodule ServiceRadar.Repo.Migrations.AddEventLedgerLateAdmissionAudit do
  @moduledoc """
  The late-admission audit trail on `event_ledger` (openspec add-edge-production-time-admission,
  Decision 7): a ledger row a `LATE_ADMISSION` delivery claimed records that it was admitted late,
  its `produced_at`, the publication and reason core's grant decided, the grant's issuer key id
  and the gateway that published it. Every other row is `admission = 'live'` with the late
  columns NULL.

  The constant default needs no table rewrite, and the check is added `NOT VALID` so the
  migration does not scan the ledger: every existing row already satisfies it through the
  default, and Postgres enforces it on every row written from now on.
  """
  use Ecto.Migration

  def up do
    schema = prefix() || "platform"

    # ALTER TABLE takes ACCESS EXCLUSIVE on the ledger. Never queue behind a long transaction:
    # fail fast and let the migration be retried.
    execute("SET LOCAL lock_timeout = '5s'")

    execute("""
    ALTER TABLE #{schema}.event_ledger
      ADD COLUMN admission text NOT NULL DEFAULT 'live',
      ADD COLUMN late_produced_at timestamptz,
      ADD COLUMN late_publication text,
      ADD COLUMN late_reason text,
      ADD COLUMN late_grant_issuer_key_id bytea,
      ADD COLUMN late_gateway_id text
    """)

    execute("""
    ALTER TABLE #{schema}.event_ledger
      ADD CONSTRAINT event_ledger_late_admission_audit_chk CHECK (
        (admission = 'live'
          AND late_produced_at IS NULL AND late_publication IS NULL AND late_reason IS NULL
          AND late_grant_issuer_key_id IS NULL AND late_gateway_id IS NULL)
        OR
        (admission = 'late'
          AND late_produced_at IS NOT NULL
          AND octet_length(late_grant_issuer_key_id) = 16
          AND ((late_publication = 'primary' AND late_reason = 'admitted')
            OR (late_publication = 'audit' AND late_reason IN (
                  'fenced_at_production', 'history_unknown', 'compromise_ended',
                  'beyond_late_window', 'ledger_pruned', 'contract_retired'))))
      ) NOT VALID
    """)
  end

  def down do
    schema = prefix() || "platform"

    execute("SET LOCAL lock_timeout = '5s'")

    execute("""
    ALTER TABLE #{schema}.event_ledger
      DROP CONSTRAINT IF EXISTS event_ledger_late_admission_audit_chk,
      DROP COLUMN IF EXISTS late_gateway_id,
      DROP COLUMN IF EXISTS late_grant_issuer_key_id,
      DROP COLUMN IF EXISTS late_reason,
      DROP COLUMN IF EXISTS late_publication,
      DROP COLUMN IF EXISTS late_produced_at,
      DROP COLUMN IF EXISTS admission
    """)
  end
end
