defmodule ServiceRadar.Repo.Migrations.CompactNetflowProviderCidrIndexes do
  @moduledoc """
  Rebuilds `platform.netflow_provider_cidrs` indexes so snapshot rotation
  does not leak deleted btree/GiST pages.

  Issue #4281 reports 2.4 MB per row. That figure could not be reproduced against
  this table and the report does not name the query that produced it, so it stands
  as an unreproduced report rather than a derivation. The leak underneath it is
  measurable. Measured 2026-09-05, two retained snapshots of ~410k CIDRs each,
  821,788 rows total:

      pg_relation_size         123 MiB  (82 MiB of tuples, avg 105 B per row)
      pkey                    5002 MiB  640,289 pages, 631,327 (98.6%) deleted
      cidr GiST               3020 MiB
      snapshot/provider        371 MiB   47,466 pages,  46,768 (98.5%) deleted
      pg_total_relation_size  8519 MiB

  The measured per-row size is 10.6 KiB against 105 B of content, and the two
  btrees hold 75 MiB of live pages inside 5373 MiB of index. The previous primary
  key was `(snapshot_id, cidr, provider)`, so every promoted snapshot is a new
  leading-key range: pruning the previous snapshot empties whole pages that the
  next rotation never descends into and so cannot refill.

  This rebuild reclaims the pages the `snapshot_id`-leading btrees and the GiST
  index have already leaked, and leading with `cidr` keeps the same CIDR from
  consecutive snapshots adjacent so vacuumed holes stay reusable; the writer emits
  rows in that order. No access method changes.

  `netflow_provider_cidrs_snapshot_provider_idx` keeps `(snapshot_id, provider)`
  because snapshot pruning deletes by `snapshot_id`, so it is rebuilt with the same
  definition to reclaim leaked pages rather than reordered or dropped.
  """

  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  @schema "platform"
  @table "netflow_provider_cidrs"
  @new_uidx "netflow_provider_cidrs_cidr_provider_snapshot_uidx"
  @old_uidx "netflow_provider_cidrs_snapshot_cidr_provider_uidx"
  @cidr_idx "netflow_provider_cidrs_cidr_idx"
  @snapshot_idx "netflow_provider_cidrs_snapshot_provider_idx"
  @pkey "netflow_provider_cidrs_pkey"

  def up do
    execute("SET statement_timeout TO 0")

    execute("""
    CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS #{@new_uidx}
      ON #{@schema}.#{@table} (cidr, provider, snapshot_id)
    """)

    execute("""
    ALTER TABLE #{@schema}.#{@table}
      DROP CONSTRAINT IF EXISTS #{@pkey}
    """)

    execute("""
    ALTER TABLE #{@schema}.#{@table}
      ADD CONSTRAINT #{@pkey}
      PRIMARY KEY USING INDEX #{@new_uidx}
    """)

    execute("DROP INDEX CONCURRENTLY IF EXISTS #{@schema}.#{@cidr_idx}")

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS #{@cidr_idx}
      ON #{@schema}.#{@table} USING gist (cidr inet_ops)
    """)

    execute("DROP INDEX CONCURRENTLY IF EXISTS #{@schema}.#{@snapshot_idx}")

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS #{@snapshot_idx}
      ON #{@schema}.#{@table} (snapshot_id, provider)
    """)
  end

  def down do
    execute("SET statement_timeout TO 0")

    execute("""
    CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS #{@old_uidx}
      ON #{@schema}.#{@table} (snapshot_id, cidr, provider)
    """)

    execute("""
    ALTER TABLE #{@schema}.#{@table}
      DROP CONSTRAINT IF EXISTS #{@pkey}
    """)

    execute("""
    ALTER TABLE #{@schema}.#{@table}
      ADD CONSTRAINT #{@pkey}
      PRIMARY KEY USING INDEX #{@old_uidx}
    """)
  end
end
