defmodule ServiceRadar.Repo.Migrations.AddNetflowCacheRefreshIndexes do
  @moduledoc false
  use Ecto.Migration

  # Timescale hypertables do not support CREATE INDEX CONCURRENTLY. Keep this
  # outside the migration transaction so Timescale can build per-chunk indexes.
  @disable_ddl_transaction true

  def up do
    execute("""
    CREATE INDEX IF NOT EXISTS idx_ocsf_network_activity_time_sampler_nonempty
      ON #{prefix() || "platform"}.ocsf_network_activity (time DESC, sampler_address)
      WHERE sampler_address IS NOT NULL AND sampler_address <> ''
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_ocsf_network_activity_time_input_snmp_sampler
      ON #{prefix() || "platform"}.ocsf_network_activity (
        time DESC,
        sampler_address,
        (ocsf_payload #>> '{connection_info,input_snmp}')
      )
      WHERE sampler_address IS NOT NULL
        AND sampler_address <> ''
        AND (ocsf_payload #>> '{connection_info,input_snmp}') IS NOT NULL
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_ocsf_network_activity_time_output_snmp_sampler
      ON #{prefix() || "platform"}.ocsf_network_activity (
        time DESC,
        sampler_address,
        (ocsf_payload #>> '{connection_info,output_snmp}')
      )
      WHERE sampler_address IS NOT NULL
        AND sampler_address <> ''
        AND (ocsf_payload #>> '{connection_info,output_snmp}') IS NOT NULL
    """)
  end

  def down do
    execute(
      "DROP INDEX IF EXISTS #{prefix() || "platform"}.idx_ocsf_network_activity_time_output_snmp_sampler"
    )

    execute(
      "DROP INDEX IF EXISTS #{prefix() || "platform"}.idx_ocsf_network_activity_time_input_snmp_sampler"
    )

    execute(
      "DROP INDEX IF EXISTS #{prefix() || "platform"}.idx_ocsf_network_activity_time_sampler_nonempty"
    )
  end
end
