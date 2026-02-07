defmodule ServiceRadar.Repo.Migrations.AddOcsfNetworkActivityAsnIndexes do
  @moduledoc """
  Adds indexes to support ASN-based flow filtering and grouping.

  This is idempotent and safe to re-run.
  """
  use Ecto.Migration

  @table "ocsf_network_activity"

  def up do
    execute("""
    CREATE INDEX IF NOT EXISTS idx_ocsf_network_activity_src_asn_time
      ON #{prefix()}.#{@table} (src_as_number, time DESC)
      WHERE src_as_number IS NOT NULL
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_ocsf_network_activity_dst_asn_time
      ON #{prefix()}.#{@table} (dst_as_number, time DESC)
      WHERE dst_as_number IS NOT NULL
    """)
  end

  def down do
    execute("DROP INDEX IF EXISTS #{prefix()}.idx_ocsf_network_activity_dst_asn_time")
    execute("DROP INDEX IF EXISTS #{prefix()}.idx_ocsf_network_activity_src_asn_time")
  end
end

