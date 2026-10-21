defmodule ServiceRadar.Repo.Migrations.AddPluginUpdatePolicy do
  @moduledoc """
  Adds the Wasm plugin update policy to its two owners, manual assignments
  (`plugin_assignments`) and target policies (`plugin_target_policies`), for
  `redesign-wasm-plugin-management`.

  * `update_policy` is `track_latest_approved` or `pinned`, default `pinned`.
  * `update_policy_source` records who chose that value: `migration_default` or
    `operator`. The column is added with the constant default
    `migration_default`, so every row that exists now is marked as a migration
    default; the default is then switched to `operator` for rows created later.

  Both steps are catalog-only: a constant default on `ADD COLUMN` does not
  rewrite the table, and `SET DEFAULT` changes only the catalog.

  Existing rows whose package is a signed, verified first-party package are moved
  to `track_latest_approved` after startup by
  `ServiceRadar.Plugins.PluginUpdatePolicyBackfillWorker`, which this migration
  enqueues once. It only touches rows still marked `migration_default`, so an
  operator choice made before or during the backfill is never overwritten.

  serviceradar:allow-startup-maintenance - nothing here updates or deletes
  existing rows during `up`. The one DELETE, in `down`, removes only this
  migration's own pending backfill job.
  """

  use Ecto.Migration

  @prefix "platform"
  @tables ["plugin_assignments", "plugin_target_policies"]
  @backfill_worker "ServiceRadar.Plugins.PluginUpdatePolicyBackfillWorker"

  def up do
    execute("SET LOCAL lock_timeout = '5s'")

    for table <- @tables do
      execute("""
      ALTER TABLE #{@prefix}.#{table}
        ADD COLUMN update_policy text NOT NULL DEFAULT 'pinned',
        ADD COLUMN update_policy_source text NOT NULL DEFAULT 'migration_default'
      """)

      execute("""
      ALTER TABLE #{@prefix}.#{table}
        ALTER COLUMN update_policy_source SET DEFAULT 'operator'
      """)
    end

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

    for table <- @tables do
      execute("""
      ALTER TABLE #{@prefix}.#{table}
        DROP COLUMN IF EXISTS update_policy_source,
        DROP COLUMN IF EXISTS update_policy
      """)
    end
  end
end
