defmodule ServiceRadar.Repo.Migrations.RepairNotificationIntegrityConstraints do
  @moduledoc """
  Repairs two notification constraints that only fail when referenced rows are
  deleted.

  Suppression decisions outlive alerts, policies, and channels, whose foreign
  keys are therefore `ON DELETE SET NULL`. The original NULLS-NOT-DISTINCT
  identity used those mutable FK columns directly. Once two otherwise-equal
  decisions lost the one parent id that distinguished them, PostgreSQL rejected
  the parent deletion with a unique violation. Immutable identity snapshots
  preserve both the dedupe behavior and the retained audit rows.

  A wasm notification provider cannot exist without its plugin package because
  `notification_providers_plugin_ref` requires `plugin_package_id`. Its original
  `ON DELETE SET NULL` action consequently turned every package deletion into a
  check-constraint failure. `ON DELETE RESTRICT` states the real lifecycle rule
  directly and reports the dependency at the foreign key.
  """

  use Ecto.Migration

  @prefix "platform"

  def up do
    alter table(:notification_deliveries, prefix: @prefix) do
      add(:suppression_alert_id, :uuid)
      add(:suppression_policy_id, :uuid)
      add(:suppression_channel_id, :uuid)
    end

    execute("""
    UPDATE #{@prefix}.notification_deliveries
       SET suppression_alert_id = alert_id,
           suppression_policy_id = policy_id,
           suppression_channel_id = channel_id
     WHERE state = 'suppressed'
    """)

    execute("DROP INDEX #{@prefix}.notification_deliveries_suppression_uidx")

    execute("""
    CREATE UNIQUE INDEX notification_deliveries_suppression_uidx
      ON #{@prefix}.notification_deliveries
        (suppression_alert_id, suppression_policy_id, step_number,
         suppression_channel_id, dedupe_key, suppression_reason)
      NULLS NOT DISTINCT
      WHERE state = 'suppressed'
    """)

    execute("""
    ALTER TABLE #{@prefix}.notification_providers
      DROP CONSTRAINT notification_providers_plugin_package_id_fkey,
      ADD CONSTRAINT notification_providers_plugin_package_id_fkey
        FOREIGN KEY (plugin_package_id)
        REFERENCES #{@prefix}.plugin_packages(id)
        ON DELETE RESTRICT
    """)
  end

  def down do
    execute("""
    ALTER TABLE #{@prefix}.notification_providers
      DROP CONSTRAINT notification_providers_plugin_package_id_fkey,
      ADD CONSTRAINT notification_providers_plugin_package_id_fkey
        FOREIGN KEY (plugin_package_id)
        REFERENCES #{@prefix}.plugin_packages(id)
        ON DELETE SET NULL
    """)

    execute("DROP INDEX #{@prefix}.notification_deliveries_suppression_uidx")

    execute("""
    CREATE UNIQUE INDEX notification_deliveries_suppression_uidx
      ON #{@prefix}.notification_deliveries
        (alert_id, policy_id, step_number, channel_id, dedupe_key, suppression_reason)
      NULLS NOT DISTINCT
      WHERE state = 'suppressed'
    """)

    alter table(:notification_deliveries, prefix: @prefix) do
      remove(:suppression_alert_id)
      remove(:suppression_policy_id)
      remove(:suppression_channel_id)
    end
  end
end
