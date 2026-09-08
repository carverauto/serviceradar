defmodule ServiceRadar.Repo.Migrations.AddDiscoveredInterfacesMetadataGin do
  @moduledoc """
  GIN index on platform.discovered_interfaces.metadata so the unifi-metadata-strip
  UPDATE (TopologyStateCleanup.sanitize_non_unifi_interface_metadata/0) seeks the
  ~44 matching rows instead of Parallel Seq Scanning both hypertable chunks.

  IMPORTANT — opclass: the query filters with `metadata ?| ARRAY[...]` (key-existence).
  That operator is only supported by the DEFAULT `jsonb_ops` GIN opclass; the smaller
  `jsonb_path_ops` does NOT index `?`/`?|`/`?&` (only @>, @?, @@), so a jsonb_path_ops
  index would be silently ignored and the planner would fall back to a Seq Scan. Use
  the default opclass. Verified live: cost 102513 -> 301 (Bitmap Index Scan).

  discovered_interfaces is a TimescaleDB hypertable; CREATE INDEX CONCURRENTLY is
  rejected on hypertables, so this builds plain (Timescale propagates to chunks). The
  brief per-chunk write lock is acceptable for this low-write maintenance table.
  """

  use Ecto.Migration

  def up do
    execute("""
    CREATE INDEX IF NOT EXISTS discovered_interfaces_metadata_gin_idx
    ON platform.discovered_interfaces
    USING GIN (metadata)
    """)
  end

  def down do
    execute("DROP INDEX IF EXISTS platform.discovered_interfaces_metadata_gin_idx")
  end
end
