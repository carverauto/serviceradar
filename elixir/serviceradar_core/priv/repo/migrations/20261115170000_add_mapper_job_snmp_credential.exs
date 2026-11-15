defmodule ServiceRadar.Repo.Migrations.AddMapperJobSnmpCredential do
  @moduledoc """
  Gives each mapper discovery job its own SNMP credential, for
  `decouple-mapper-discovery-credential`.

  * `snmp_credential_secret_id` references the reusable SNMP credential the job
    falls back on for addresses without a per-device credential. The foreign key
    restricts deletion, so a credential in use cannot be removed under a job.
  * `snmp_credential_backfill_pending` marks the jobs that existed before this
    migration. The column is added with the constant default `true`, so every
    existing row is marked, and the default is then switched to `false` for jobs
    created later. Both steps are catalog-only.

  `ServiceRadar.NetworkDiscovery.MapperJobSNMPCredentialBackfillWorker`, which
  this migration enqueues once, binds each marked job to the credential its
  pre-change fallback resolved to and clears the mark. A job whose mark is
  cleared is never revisited, so an operator's later choice is never overwritten.

  serviceradar:allow-startup-maintenance - nothing here updates or deletes
  existing rows during `up`. The one DELETE, in `down`, removes only this
  migration's own pending backfill job.
  """

  use Ecto.Migration

  @prefix "platform"
  @backfill_worker "ServiceRadar.NetworkDiscovery.MapperJobSNMPCredentialBackfillWorker"

  def up do
    execute("SET LOCAL lock_timeout = '5s'")

    execute("""
    ALTER TABLE #{@prefix}.mapper_jobs
      ADD COLUMN snmp_credential_secret_id uuid
        REFERENCES #{@prefix}.network_credential_secrets(id) ON DELETE RESTRICT,
      ADD COLUMN snmp_credential_backfill_pending boolean NOT NULL DEFAULT true
    """)

    execute("""
    ALTER TABLE #{@prefix}.mapper_jobs
      ALTER COLUMN snmp_credential_backfill_pending SET DEFAULT false
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS mapper_jobs_snmp_credential_secret_idx
      ON #{@prefix}.mapper_jobs (snmp_credential_secret_id)
      WHERE snmp_credential_secret_id IS NOT NULL
    """)

    execute("""
    INSERT INTO #{@prefix}.oban_jobs (state, queue, worker, args, max_attempts)
    VALUES ('available', 'maintenance', '#{@backfill_worker}',
            '{"trigger": "migration"}'::jsonb, 20)
    """)
  end

  def down do
    execute("SET LOCAL lock_timeout = '5s'")

    execute("""
    DELETE FROM #{@prefix}.oban_jobs
    WHERE worker = '#{@backfill_worker}' AND state IN ('available', 'scheduled', 'retryable')
    """)

    execute("DROP INDEX IF EXISTS #{@prefix}.mapper_jobs_snmp_credential_secret_idx")

    execute("""
    ALTER TABLE #{@prefix}.mapper_jobs
      DROP COLUMN IF EXISTS snmp_credential_backfill_pending,
      DROP COLUMN IF EXISTS snmp_credential_secret_id
    """)
  end
end
