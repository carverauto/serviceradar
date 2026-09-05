defmodule ServiceRadar.Repo.Migrations.CompactNetflowProviderCidrIndexes do
  @moduledoc """
  Rebuilds the three indexes on `platform.netflow_provider_cidrs` to return the
  space their files still hold. Nothing is redefined: same primary key columns,
  same secondary keys, same access methods.

  Issue #4281 reports 2.4 MB per row. That is a relation size over a row count, and
  the numerator is the part that is wrong: 8519 MiB of files holding 82 MiB of
  tuples. The denominator the report implies -- 8519 MiB / 2.4 MiB is about 3,550
  rows -- was never observed. It is inferred from the reported ratio, not measured.

  What was measured is that the ratio moves entirely with the denominator. Two
  readings on 2026-09-05, before and after a prune, `n_live_tup` equal to `count(*)`
  on both:

      2 snapshots   821,788 rows   10.6 KiB per row
      1 snapshot    410,899 rows   21.2 KiB per row

  The three index files measured 5002 / 3020 / 371 MiB at both readings: half the
  rows went away and not one page came back. Per-index detail from the first:

      pg_relation_size         123 MiB  (82 MiB of tuples, avg 105 B per row)
      pkey                    5002 MiB  640,289 pages, 631,327 (98.6%) deleted
      cidr GiST               3020 MiB
      snapshot/provider        371 MiB   47,466 pages,  46,768 (98.5%) deleted
      pg_total_relation_size  8519 MiB

  So what the btrees hold is a high-water mark rather than an active leak. 8,961 of
  the primary key's 640,289 pages carried all 821,788 entries live at the first
  reading; the rest are marked deleted, which makes them available for reuse but
  never hands them back to the OS, because no VACUUM truncates a btree -- only a
  rebuild does. At 4,440 leaf pages per snapshot that file is sized for about 144
  snapshots' worth, far more history than retention now keeps, so the pages are
  free and simply stay unused.

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
