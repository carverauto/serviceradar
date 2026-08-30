defmodule ServiceRadar.Repo.Migrations.AddPluginContributedSNMPProvenance do
  @moduledoc """
  Survives package deletion so the SNMP UI can still say a row was plugin
  contributed. `plugin_package_id` nilifies on package delete; without this
  flag a removed package's profile is indistinguishable from one an operator
  wrote themselves.
  """

  use Ecto.Migration

  def up do
    for table <- [:snmp_oid_templates, :snmp_profiles] do
      alter table(table, prefix: "platform") do
        add_if_not_exists :plugin_contributed, :boolean, null: false, default: false
      end

      execute """
      UPDATE platform.#{table}
      SET plugin_contributed = true
      WHERE plugin_package_id IS NOT NULL
      """
    end
  end

  def down do
    for table <- [:snmp_oid_templates, :snmp_profiles] do
      alter table(table, prefix: "platform") do
        remove_if_exists :plugin_contributed, :boolean
      end
    end
  end
end
