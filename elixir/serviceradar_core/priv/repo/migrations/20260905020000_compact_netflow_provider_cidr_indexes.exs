defmodule ServiceRadar.Repo.Migrations.CompactNetflowProviderCidrIndexes do
  @moduledoc """
  Rebuilds `platform.netflow_provider_cidrs` indexes so snapshot rotation
  does not leak deleted btree/GiST pages.

  The previous primary key was `(snapshot_id, cidr, provider)`. Each promoted
  snapshot is a new leading-key range, so deleting the previous snapshot leaves
  btree pages autovacuum cannot reuse. Demo measured 123MB heap / 821k rows
  (avg 100B, max 328B) against 5GB PK + 3GB GiST, 98% deleted pages.

  Leading with `cidr` keeps the same CIDR from consecutive snapshots adjacent
  so vacuumed holes are reusable. SP-GiST `inet_ops` replaces GiST for the
  `<<=` fallback (the in-memory provider trie is the primary lookup).

  `netflow_provider_cidrs_snapshot_provider_idx` keeps `(snapshot_id, provider)`
  because snapshot pruning deletes by `snapshot_id`, so it is rebuilt in place to
  reclaim the pages rotation already leaked rather than reordered or dropped.
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
      ON #{@schema}.#{@table} USING spgist (cidr inet_ops)
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

    execute("DROP INDEX CONCURRENTLY IF EXISTS #{@schema}.#{@cidr_idx}")

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS #{@cidr_idx}
      ON #{@schema}.#{@table} USING gist (cidr inet_ops)
    """)
  end
end
