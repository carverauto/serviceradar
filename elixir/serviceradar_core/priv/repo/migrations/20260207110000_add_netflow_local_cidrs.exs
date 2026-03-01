defmodule ServiceRadar.Repo.Migrations.AddNetflowLocalCidrs do
  @moduledoc """
  Adds the NetFlow local CIDR configuration table.

  This table is used by SRQL (and background enrichment) to classify flow
  directionality (inbound/outbound/internal/external) based on a deployment's
  configured "local" networks.
  """

  use Ecto.Migration

  def up do
    # Use raw SQL to keep this migration idempotent even if the table is created
    # out-of-band in dev environments.
    execute("""
    CREATE TABLE IF NOT EXISTS platform.netflow_local_cidrs (
      id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
      partition TEXT,
      label TEXT,
      cidr CIDR NOT NULL,
      enabled BOOLEAN NOT NULL DEFAULT true,
      inserted_at TIMESTAMPTZ,
      updated_at TIMESTAMPTZ
    )
    """)

    execute(
      "CREATE INDEX IF NOT EXISTS netflow_local_cidrs_partition_idx ON platform.netflow_local_cidrs (partition)"
    )

    execute(
      "CREATE INDEX IF NOT EXISTS netflow_local_cidrs_enabled_idx ON platform.netflow_local_cidrs (enabled)"
    )

    execute(
      "CREATE UNIQUE INDEX IF NOT EXISTS netflow_local_cidrs_partition_cidr_uidx ON platform.netflow_local_cidrs (partition, cidr)"
    )

    execute("""
    CREATE INDEX IF NOT EXISTS netflow_local_cidrs_cidr_gist_enabled_idx
    ON platform.netflow_local_cidrs
    USING GIST (cidr inet_ops)
    WHERE enabled
    """)
  end

  def down do
    execute("DROP INDEX IF EXISTS platform.netflow_local_cidrs_cidr_gist_enabled_idx")
    execute("DROP INDEX IF EXISTS platform.netflow_local_cidrs_partition_cidr_uidx")
    execute("DROP INDEX IF EXISTS platform.netflow_local_cidrs_enabled_idx")
    execute("DROP INDEX IF EXISTS platform.netflow_local_cidrs_partition_idx")
    execute("DROP TABLE IF EXISTS platform.netflow_local_cidrs")
  end
end
