defmodule ServiceRadar.Repo.Migrations.DropUnusedAdvisoryIndexes do
  @moduledoc """
  Drops three advisory-storage indexes that no query in the tree can use
  (code-side review in #5751, comment 6383293422):

    * `vulnerability_advisories_raw_gin_idx` (`raw jsonb_path_ops`): serves
      jsonb containment/jsonpath predicates. Nothing issues one against
      `raw`; the column is written at ingest and selected whole for
      in-Elixir extraction. Provenance needs the column, not the index.
    * `vulnerability_advisories_coordinates_gin_idx` (GIN on
      `affected_coordinates`): the loader now always writes
      `affected_coordinates: []`, so this indexes empty arrays.
    * `advisory_coordinates_generation_idx` (`provider, feed_key,
      generation`): the matcher scopes reads through the advisory side
      (`current` plus provider/feed on `vulnerability_advisories`),
      generation reaping deletes advisories and coordinates follow by FK
      cascade, and the loader deliberately never reads the column (it is
      excluded from the upsert replace list so byte-identical coordinates
      stay HOT). No SRQL filter names these columns either.

  Indexes with live consumers stay: the `(cpe_vendor, cpe_product)`
  component index the matcher now drives, the trigram on coordinate
  `value` behind SRQL wildcard filters, the type/value and identity
  indexes, and the endpoint-package `cpes`/purl indexes SRQL emits
  `&&`/`=`/`= ANY` predicates for.

  Dropped `CONCURRENTLY` (with `@disable_ddl_transaction` /
  `@disable_migration_lock`) so the drop does not take an
  `ACCESS EXCLUSIVE` lock on write-hot tables. The `down` recreates all
  three exactly as originally defined; expect those builds to take as
  long as any large GIN build if a rollback is ever needed.
  """

  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("DROP INDEX CONCURRENTLY IF EXISTS platform.vulnerability_advisories_raw_gin_idx")

    execute(
      "DROP INDEX CONCURRENTLY IF EXISTS platform.vulnerability_advisories_coordinates_gin_idx"
    )

    execute("DROP INDEX CONCURRENTLY IF EXISTS platform.advisory_coordinates_generation_idx")
  end

  def down do
    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS vulnerability_advisories_raw_gin_idx
      ON platform.vulnerability_advisories
      USING GIN (raw jsonb_path_ops)
    """)

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS vulnerability_advisories_coordinates_gin_idx
      ON platform.vulnerability_advisories
      USING GIN (affected_coordinates)
    """)

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS advisory_coordinates_generation_idx
      ON platform.advisory_coordinates (provider, feed_key, generation)
    """)
  end
end
