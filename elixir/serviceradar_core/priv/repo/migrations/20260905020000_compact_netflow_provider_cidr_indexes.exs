defmodule ServiceRadar.Repo.Migrations.CompactNetflowProviderCidrIndexes do
  @moduledoc """
  Reclaims the deleted pages `platform.netflow_provider_cidrs` has leaked, and
  reorders the primary key so snapshot rotation stops refilling them there.

  Issue #4281 reports 2.4 MB per row. That is this relation over `n_live_tup`, not
  a per-row encoding size: 8519 MiB divided by ~3,550 is 2.4 MiB, and ~3,550 is the
  live-tuple estimate, not the 821,788 rows present. `n_live_tup` is a statistics
  estimate that falls as each prune batch commits and is only recomputed by
  VACUUM/ANALYZE, so mid-rotation it reads far below the true count; once it
  catches up the same relation reads 10.6 KiB per row. Both figures divide the same
  leaked index pages, so they are one defect seen at two moments of the rotation
  cycle. Measured 2026-09-05, two retained snapshots of ~410k CIDRs each, 821,788
  rows total:

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
  definition rather than reordered or dropped. That reclaims its 371 MiB once and
  no more: the key is still snapshot_id-leading, so rotation will accumulate
  deleted pages in it again by the same mechanism. It packs about 1,200 entries
  per leaf page against the primary key's 93, so it leaks roughly 13x slower.
  Reclaiming that residue is follow-up work, not this change.
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

    execute("DROP INDEX CONCURRENTLY IF EXISTS #{@schema}.#{@new_uidx}")

    execute("""
    CREATE UNIQUE INDEX CONCURRENTLY #{@new_uidx}
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

    execute("DROP INDEX CONCURRENTLY IF EXISTS #{@schema}.#{@old_uidx}")

    execute("""
    CREATE UNIQUE INDEX CONCURRENTLY #{@old_uidx}
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
