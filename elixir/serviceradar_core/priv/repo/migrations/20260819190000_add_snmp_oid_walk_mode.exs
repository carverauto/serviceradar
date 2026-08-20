defmodule ServiceRadar.Repo.Migrations.AddSnmpOidWalkMode do
  @moduledoc """
  Persist SNMP OID retrieval mode so table walks can be configured
  from the control plane and compiled onto the agent proto config.
  """

  use Ecto.Migration

  def up do
    alter table(:snmp_oid_configs, prefix: "platform") do
      add :mode, :text, null: false, default: "get"
      add :max_rows, :integer
      add :walk_timeout_seconds, :integer
    end

    create constraint(:snmp_oid_configs, :snmp_oid_configs_mode_check,
             check: "mode IN ('get', 'walk')",
             prefix: "platform"
           )

    create constraint(:snmp_oid_configs, :snmp_oid_configs_max_rows_check,
             check: "max_rows IS NULL OR max_rows >= 1",
             prefix: "platform"
           )

    create constraint(:snmp_oid_configs, :snmp_oid_configs_walk_timeout_seconds_check,
             check: "walk_timeout_seconds IS NULL OR walk_timeout_seconds >= 1",
             prefix: "platform"
           )
  end

  def down do
    drop constraint(:snmp_oid_configs, :snmp_oid_configs_walk_timeout_seconds_check,
           prefix: "platform"
         )

    drop constraint(:snmp_oid_configs, :snmp_oid_configs_max_rows_check, prefix: "platform")
    drop constraint(:snmp_oid_configs, :snmp_oid_configs_mode_check, prefix: "platform")

    alter table(:snmp_oid_configs, prefix: "platform") do
      remove :walk_timeout_seconds
      remove :max_rows
      remove :mode
    end
  end
end
