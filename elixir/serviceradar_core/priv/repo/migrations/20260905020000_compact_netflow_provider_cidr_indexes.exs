defmodule ServiceRadar.Repo.Migrations.CompactNetflowProviderCidrIndexes do
  @moduledoc """
  Rebuilds the three indexes on `platform.netflow_provider_cidrs` to return the
  space their files still hold. Nothing is redefined: same primary key columns,
  same secondary keys, same access methods.

  Issue #4281 reports 2.4 MB per row. That is this relation over `n_live_tup`, not
  a per-row encoding size: 8519 MiB divided by ~3,550 is 2.4 MiB, and ~3,550 is the
  live-tuple estimate, not the 821,788 rows present. `n_live_tup` is a statistics
  estimate that falls as each prune batch commits and is only recomputed by
  VACUUM/ANALYZE, so mid-rotation it reads far below the true count; once it
  catches up the same relation reads 10.6 KiB per row. Measured 2026-09-05, two
  retained snapshots of ~410k CIDRs each, 821,788 rows total:

      pg_relation_size         123 MiB  (82 MiB of tuples, avg 105 B per row)
      pkey                    5002 MiB  640,289 pages, 631,327 (98.6%) deleted
      cidr GiST               3020 MiB
      snapshot/provider        371 MiB   47,466 pages,  46,768 (98.5%) deleted
      pg_total_relation_size  8519 MiB

  What the btrees hold is a high-water mark rather than an active leak. 8,961 of
  the primary key's 640,289 pages carry all 821,788 live entries; the rest are
  marked deleted, which makes them available for reuse but never hands them back
  to the OS, because no VACUUM truncates a btree -- only a rebuild does. At 4,440
  leaf pages per snapshot the file is sized for about 144 snapshots' worth, and
  `DatasetSnapshotPrune` records that before it existed the nightly 14-day window
  "left a dozen inactive copies in demo". Retention is two snapshots now, so those
  pages are free and simply stay unused.

  This migration reclaims that space once. It does not establish what drove each
  file to its size, so whether any of them regrow is unsettled here -- including
  the 3020 MiB GiST index, which is keyed on `cidr` alone and so was never
  partitioned by snapshot at all. Watching the sizes across a few rotations is
  follow-up work, not this change.
  """

  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  @schema "platform"
  @table "netflow_provider_cidrs"
  @pkey_uidx "netflow_provider_cidrs_snapshot_cidr_provider_uidx"
  @cidr_idx "netflow_provider_cidrs_cidr_idx"
  @snapshot_idx "netflow_provider_cidrs_snapshot_provider_idx"
  @pkey "netflow_provider_cidrs_pkey"

  def up do
    execute("SET statement_timeout TO 0")

    execute("DROP INDEX CONCURRENTLY IF EXISTS #{@schema}.#{@pkey_uidx}")

    execute("""
    CREATE UNIQUE INDEX CONCURRENTLY #{@pkey_uidx}
      ON #{@schema}.#{@table} (snapshot_id, cidr, provider)
    """)

    execute("""
    ALTER TABLE #{@schema}.#{@table}
      DROP CONSTRAINT IF EXISTS #{@pkey}
    """)

    execute("""
    ALTER TABLE #{@schema}.#{@table}
      ADD CONSTRAINT #{@pkey}
      PRIMARY KEY USING INDEX #{@pkey_uidx}
    """)

    execute("DROP INDEX CONCURRENTLY IF EXISTS #{@schema}.#{@cidr_idx}")

    execute("""
    CREATE INDEX CONCURRENTLY #{@cidr_idx}
      ON #{@schema}.#{@table} USING gist (cidr inet_ops)
    """)

    execute("DROP INDEX CONCURRENTLY IF EXISTS #{@schema}.#{@snapshot_idx}")

    execute("""
    CREATE INDEX CONCURRENTLY #{@snapshot_idx}
      ON #{@schema}.#{@table} (snapshot_id, provider)
    """)
  end

  def down, do: :ok
end
