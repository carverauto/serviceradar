defmodule ServiceRadar.Repo.Migrations.AddSnmpMaxTargetsToEdgePipelineSettings do
  @moduledoc """
  Adds `snmp_max_targets` to `edge_pipeline_settings`: the most targets one SNMP profile may
  compile for one agent, at global, partition or agent scope. NULL inherits from the wider
  scope, and the code default applies when no scope sets it
  (`ServiceRadar.Edge.PipelineSettings.default_snmp_max_targets/0`).
  """
  use Ecto.Migration

  @table "edge_pipeline_settings"

  def up do
    schema = prefix() || "platform"

    execute("""
    ALTER TABLE #{schema}.#{@table}
      ADD COLUMN snmp_max_targets INTEGER,
      ADD CONSTRAINT #{@table}_snmp_max_targets_chk
        CHECK (snmp_max_targets IS NULL OR snmp_max_targets >= 1)
    """)
  end

  def down do
    schema = prefix() || "platform"

    execute("""
    ALTER TABLE #{schema}.#{@table}
      DROP CONSTRAINT #{@table}_snmp_max_targets_chk,
      DROP COLUMN snmp_max_targets
    """)
  end
end
