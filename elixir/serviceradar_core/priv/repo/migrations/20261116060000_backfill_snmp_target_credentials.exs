defmodule ServiceRadar.Repo.Migrations.BackfillSnmpTargetCredentials do
  @moduledoc """
  Enqueues the one-off backfill for `remove-snmp-unbound-host-rule-fallback`.

  An explicit SNMP target whose host belongs to no device is no longer polled
  with the first SNMP monitoring rule scoped to the compiling agent.
  `ServiceRadar.SNMPProfiles.SNMPTargetCredentialBackfillWorker` binds each
  target that only that fallback kept polling to the rule's reusable
  credential, so it keeps polling without anyone re-entering a secret.

  serviceradar:allow-startup-maintenance - `up` only inserts one Oban job and
  changes no existing row; the worker does the backfill after boot. The one
  DELETE, in `down`, removes only this migration's own pending job.
  """

  use Ecto.Migration

  @prefix "platform"
  @backfill_worker "ServiceRadar.SNMPProfiles.SNMPTargetCredentialBackfillWorker"

  def up do
    execute("""
    INSERT INTO #{@prefix}.oban_jobs (state, queue, worker, args, max_attempts)
    VALUES ('available', 'maintenance', '#{@backfill_worker}',
            '{"trigger": "migration"}'::jsonb, 20)
    """)
  end

  def down do
    execute("""
    DELETE FROM #{@prefix}.oban_jobs
    WHERE worker = '#{@backfill_worker}' AND state IN ('available', 'scheduled', 'retryable')
    """)
  end
end
