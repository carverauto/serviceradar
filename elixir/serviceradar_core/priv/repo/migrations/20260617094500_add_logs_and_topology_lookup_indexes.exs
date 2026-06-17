defmodule ServiceRadar.Repo.Migrations.AddLogsAndTopologyLookupIndexes do
  @moduledoc false
  use Ecto.Migration

  @disable_ddl_transaction true

  def up do
    execute("CREATE EXTENSION IF NOT EXISTS pg_trgm WITH SCHEMA platform")

    execute("""
    CREATE INDEX IF NOT EXISTS idx_logs_resource_attributes_trgm
    ON platform.logs
    USING gin ((COALESCE(resource_attributes, '')) gin_trgm_ops)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_logs_attributes_trgm
    ON platform.logs
    USING gin ((COALESCE(attributes, '')) gin_trgm_ops)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_logs_body_trgm
    ON platform.logs
    USING gin ((COALESCE(body, '')) gin_trgm_ops)
    """)

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_mapper_topology_links_local_device_id
    ON platform.mapper_topology_links (local_device_id)
    WHERE local_device_id IS NOT NULL
    """)

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_mapper_topology_links_neighbor_device_id
    ON platform.mapper_topology_links (neighbor_device_id)
    WHERE neighbor_device_id IS NOT NULL
    """)

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_mapper_topology_links_local_default_ip
    ON platform.mapper_topology_links ((SPLIT_PART(local_device_id, 'default:', 2)))
    WHERE local_device_id LIKE 'default:%'
    """)

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_mapper_topology_links_neighbor_default_ip
    ON platform.mapper_topology_links ((SPLIT_PART(neighbor_device_id, 'default:', 2)))
    WHERE neighbor_device_id LIKE 'default:%'
    """)

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_mapper_topology_links_local_invalid_literal
    ON platform.mapper_topology_links ((LOWER(BTRIM(COALESCE(local_device_id, '')))))
    WHERE LOWER(BTRIM(COALESCE(local_device_id, ''))) IN ('nil', 'null', 'undefined')
    """)

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_mapper_topology_links_neighbor_invalid_literal
    ON platform.mapper_topology_links ((LOWER(BTRIM(COALESCE(neighbor_device_id, '')))))
    WHERE LOWER(BTRIM(COALESCE(neighbor_device_id, ''))) IN ('nil', 'null', 'undefined')
    """)
  end

  def down do
    execute(
      "DROP INDEX CONCURRENTLY IF EXISTS platform.idx_mapper_topology_links_neighbor_invalid_literal"
    )

    execute(
      "DROP INDEX CONCURRENTLY IF EXISTS platform.idx_mapper_topology_links_local_invalid_literal"
    )

    execute(
      "DROP INDEX CONCURRENTLY IF EXISTS platform.idx_mapper_topology_links_neighbor_default_ip"
    )

    execute(
      "DROP INDEX CONCURRENTLY IF EXISTS platform.idx_mapper_topology_links_local_default_ip"
    )

    execute(
      "DROP INDEX CONCURRENTLY IF EXISTS platform.idx_mapper_topology_links_neighbor_device_id"
    )

    execute(
      "DROP INDEX CONCURRENTLY IF EXISTS platform.idx_mapper_topology_links_local_device_id"
    )

    execute("DROP INDEX IF EXISTS platform.idx_logs_body_trgm")
    execute("DROP INDEX IF EXISTS platform.idx_logs_attributes_trgm")
    execute("DROP INDEX IF EXISTS platform.idx_logs_resource_attributes_trgm")
  end
end
