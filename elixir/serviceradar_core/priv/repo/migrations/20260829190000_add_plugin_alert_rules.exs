defmodule ServiceRadar.Repo.Migrations.AddPluginAlertRules do
  @moduledoc """
  Lets a plugin package propose alert rules that an operator approves.

  Two columns:

    * `plugin_packages.alert_rules` — the manifest's declarations, stored on the
      package exactly as `producer_schedules` is.

    * `stateful_alert_rules.plugin_package_id` — provenance, nullable, so a rule
      knows which package contributed it. Nullable because every rule that
      exists today was authored by an operator or seeded by core, and those keep
      a NULL here.

  ON DELETE SET NULL rather than CASCADE on purpose: removing a package must not
  delete rules an operator may have tuned and come to rely on. The rule survives
  as an orphan, which is visible and recoverable; a cascade is neither.
  """

  use Ecto.Migration

  def up do
    alter table(:plugin_packages, prefix: "platform") do
      add_if_not_exists :alert_rules, {:array, :map}
    end

    alter table(:stateful_alert_rules, prefix: "platform") do
      add_if_not_exists :plugin_package_id,
                        references(:plugin_packages,
                          prefix: "platform",
                          type: :uuid,
                          on_delete: :nilify_all
                        )
    end

    create_if_not_exists index(:stateful_alert_rules, [:plugin_package_id], prefix: "platform")
  end

  def down do
    drop_if_exists index(:stateful_alert_rules, [:plugin_package_id], prefix: "platform")

    alter table(:stateful_alert_rules, prefix: "platform") do
      remove_if_exists :plugin_package_id
    end

    alter table(:plugin_packages, prefix: "platform") do
      remove_if_exists :alert_rules
    end
  end
end
