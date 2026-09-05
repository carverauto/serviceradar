defmodule ServiceRadar.Repo.Migrations.CompactNetflowProviderCidrIndexes do
  @moduledoc """
  Rebuilds `platform.netflow_provider_cidrs` indexes so snapshot rotation
  does not leak deleted btree/GiST pages.

  The reported per-row size is `relation size / row count`, and the numerator is
  what is wrong, not the rows. Measured 2026-09-05 with two retained snapshots of
  ~410k CIDRs each, 821,788 rows total:

      pg_relation_size         123 MiB  (82 MiB of tuples, avg 105 B per row)
      pkey                    5002 MiB  640,289 pages, 631,327 (98.6%) deleted
      cidr GiST               3020 MiB
      snapshot/provider        371 MiB   47,466 pages,  46,768 (98.5%) deleted
      pg_total_relation_size  8519 MiB  = 10.6 KiB per row of 105 B content

  The two btrees hold 75 MiB of live pages inside 5373 MiB of index. The previous
  primary key was `(snapshot_id, cidr, provider)`, so every promoted snapshot is a
  new leading-key range: pruning the previous snapshot empties whole pages that the
  next rotation never descends into and so cannot refill.

  Leading with `cidr` keeps the same CIDR from consecutive snapshots adjacent so
  vacuumed holes are reusable, and the writer emits rows in that order. Rebuilding
  returns each index to its live content now; the key order is what keeps it there.
  SP-GiST `inet_ops` replaces GiST for the `<<=` fallback (the in-memory provider
  trie is the primary lookup).

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
