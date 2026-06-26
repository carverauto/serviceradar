defmodule ServiceRadar.Repo.Migrations.AddMapperTopologyLinksLogicalKeyUidx do
  @moduledoc """
  Stops `platform.mapper_topology_links` from regrowing into multi-million-row bloat.

  The mapper re-inserts the entire discovered topology every ~5 minutes. Before this
  migration the table had no unique key, so every cycle appended duplicate rows
  (append-only) and the table grew unbounded.

  This adds a UNIQUE index over the logical key of a topology edge so the ingestor can
  upsert (insert-or-update-in-place) instead of blind-appending. See
  `ServiceRadar.NetworkDiscovery.TopologyLink` (the `:logical_key` identity bound via
  `identity_index_names`) and `ServiceRadar.NetworkDiscovery.MapperResultsIngestor`
  (the TopologyLink `prepare_bulk_records/3` upsert clause).

  ## Ash identity approach (why plain columns, not COALESCE expressions)

  The logical key includes nullable columns (`neighbor_port_id`, `neighbor_chassis_id`,
  `local_if_index`, ...). A COALESCE-based expression index would NOT be inferable by
  Ash's upsert `ON CONFLICT (col, col, ...)` clause — Postgres only infers an
  expression index when the conflict target lists the exact same expressions, which
  Ash does not emit for a plain-column identity. Ash 3.x identities are over plain
  attributes/calculations, not raw SQL expressions.

  Therefore we take the least-risky route: make the six key columns `NOT NULL DEFAULT ''`
  (text) / `NOT NULL DEFAULT 0` (`local_if_index`) so the unique index is plain-column.
  Then Ash's `ON CONFLICT (local_device_id, neighbor_device_id, local_if_index,
  neighbor_port_id, protocol, neighbor_chassis_id)` matches the index exactly. The
  resource sets the same defaults + `allow_nil? false`, and the ingestor coalesces
  any nil key values to ''/0 before upsert, so the in-batch dedup key, the inserted
  values, and the index all agree.

  ## Ordering caveats

  1. Existing NULLs in the key columns are backfilled to ''/0 BEFORE `SET NOT NULL`,
     otherwise the NOT NULL would fail on legacy rows.
  2. Any residual duplicate rows (post de-bloat) are collapsed (newest `created_at`/
     `timestamp` wins) BEFORE the unique index is built; otherwise
     `CREATE UNIQUE INDEX CONCURRENTLY` would fail and leave an INVALID index behind.
  3. The index is created with `@disable_ddl_transaction true` + `@disable_migration_lock
     true` so `CONCURRENTLY` is legal (it cannot run inside a transaction block).
     The backfill / dedup / ALTER statements run as their own implicit transactions,
     which is fine without the migration-level DDL transaction.
  """

  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  @index_name "mapper_topology_links_logical_key_uidx"

  def up do
    # serviceradar:allow-startup-maintenance - schema-critical bounded cleanup
    # before adding the logical-key constraint. The mapper link table is the
    # affected table, duplicates are collapsed once, and the final unique index
    # is built CONCURRENTLY.
    # 1. Backfill legacy NULLs in the logical-key columns to their new defaults.
    execute("""
    UPDATE platform.mapper_topology_links
    SET local_device_id = COALESCE(local_device_id, ''),
        neighbor_device_id = COALESCE(neighbor_device_id, ''),
        neighbor_port_id = COALESCE(neighbor_port_id, ''),
        protocol = COALESCE(protocol, ''),
        neighbor_chassis_id = COALESCE(neighbor_chassis_id, ''),
        local_if_index = COALESCE(local_if_index, 0)
    WHERE local_device_id IS NULL
       OR neighbor_device_id IS NULL
       OR neighbor_port_id IS NULL
       OR protocol IS NULL
       OR neighbor_chassis_id IS NULL
       OR local_if_index IS NULL
    """)

    # 2. Apply NOT NULL + DEFAULT so the index can be plain-column and future
    #    inserts that omit a key column land on the default rather than NULL.
    execute("ALTER TABLE platform.mapper_topology_links ALTER COLUMN local_device_id SET DEFAULT ''")

    execute("ALTER TABLE platform.mapper_topology_links ALTER COLUMN local_device_id SET NOT NULL")

    execute("ALTER TABLE platform.mapper_topology_links ALTER COLUMN neighbor_device_id SET DEFAULT ''")

    execute("ALTER TABLE platform.mapper_topology_links ALTER COLUMN neighbor_device_id SET NOT NULL")

    execute("ALTER TABLE platform.mapper_topology_links ALTER COLUMN neighbor_port_id SET DEFAULT ''")

    execute("ALTER TABLE platform.mapper_topology_links ALTER COLUMN neighbor_port_id SET NOT NULL")

    execute("ALTER TABLE platform.mapper_topology_links ALTER COLUMN protocol SET DEFAULT ''")
    execute("ALTER TABLE platform.mapper_topology_links ALTER COLUMN protocol SET NOT NULL")

    execute("ALTER TABLE platform.mapper_topology_links ALTER COLUMN neighbor_chassis_id SET DEFAULT ''")

    execute("ALTER TABLE platform.mapper_topology_links ALTER COLUMN neighbor_chassis_id SET NOT NULL")

    execute("ALTER TABLE platform.mapper_topology_links ALTER COLUMN local_if_index SET DEFAULT 0")

    execute("ALTER TABLE platform.mapper_topology_links ALTER COLUMN local_if_index SET NOT NULL")

    # 3. Collapse any residual duplicates (newest wins) so the UNIQUE index can build.
    execute("""
    DELETE FROM platform.mapper_topology_links AS l
    USING (
      SELECT id,
        ROW_NUMBER() OVER (
          PARTITION BY local_device_id, neighbor_device_id, local_if_index,
                       neighbor_port_id, protocol, neighbor_chassis_id
          ORDER BY COALESCE(created_at, timestamp) DESC NULLS LAST, id DESC
        ) AS rn
      FROM platform.mapper_topology_links
    ) AS ranked
    WHERE l.id = ranked.id
      AND ranked.rn > 1
    """)

    # 4. Build the plain-column UNIQUE index concurrently (no table lock).
    execute("""
    CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS #{@index_name}
      ON platform.mapper_topology_links (
        local_device_id,
        neighbor_device_id,
        local_if_index,
        neighbor_port_id,
        protocol,
        neighbor_chassis_id
      )
    """)
  end

  def down do
    execute("DROP INDEX CONCURRENTLY IF EXISTS platform.#{@index_name}")

    # Leave the backfilled data in place but relax the constraints so the column
    # shapes match the original schema.
    execute("ALTER TABLE platform.mapper_topology_links ALTER COLUMN local_device_id DROP NOT NULL")

    execute("ALTER TABLE platform.mapper_topology_links ALTER COLUMN local_device_id DROP DEFAULT")

    execute("ALTER TABLE platform.mapper_topology_links ALTER COLUMN neighbor_device_id DROP NOT NULL")

    execute("ALTER TABLE platform.mapper_topology_links ALTER COLUMN neighbor_device_id DROP DEFAULT")

    execute("ALTER TABLE platform.mapper_topology_links ALTER COLUMN neighbor_port_id DROP NOT NULL")

    execute("ALTER TABLE platform.mapper_topology_links ALTER COLUMN neighbor_port_id DROP DEFAULT")

    execute("ALTER TABLE platform.mapper_topology_links ALTER COLUMN protocol DROP NOT NULL")
    execute("ALTER TABLE platform.mapper_topology_links ALTER COLUMN protocol DROP DEFAULT")

    execute("ALTER TABLE platform.mapper_topology_links ALTER COLUMN neighbor_chassis_id DROP NOT NULL")

    execute("ALTER TABLE platform.mapper_topology_links ALTER COLUMN neighbor_chassis_id DROP DEFAULT")

    execute("ALTER TABLE platform.mapper_topology_links ALTER COLUMN local_if_index DROP NOT NULL")

    execute("ALTER TABLE platform.mapper_topology_links ALTER COLUMN local_if_index DROP DEFAULT")
  end
end
