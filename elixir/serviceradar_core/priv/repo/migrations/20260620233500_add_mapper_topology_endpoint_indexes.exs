defmodule ServiceRadar.Repo.Migrations.AddMapperTopologyEndpointIndexes do
  @moduledoc false
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS mapper_topology_links_local_device_id_idx
      ON platform.mapper_topology_links (local_device_id)
      WHERE local_device_id IS NOT NULL
    """)

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS mapper_topology_links_neighbor_device_id_idx
      ON platform.mapper_topology_links (neighbor_device_id)
      WHERE neighbor_device_id IS NOT NULL
    """)
  end

  def down do
    execute(
      "DROP INDEX CONCURRENTLY IF EXISTS platform.mapper_topology_links_neighbor_device_id_idx"
    )

    execute(
      "DROP INDEX CONCURRENTLY IF EXISTS platform.mapper_topology_links_local_device_id_idx"
    )
  end
end
