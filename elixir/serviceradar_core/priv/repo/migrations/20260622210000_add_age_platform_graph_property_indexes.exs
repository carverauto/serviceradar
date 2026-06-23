defmodule ServiceRadar.Repo.Migrations.AddAgePlatformGraphPropertyIndexes do
  @moduledoc """
  Adds Apache AGE property indexes on the hot `platform_graph` vertex labels.

  Cypher `MERGE`/`MATCH (Label {id: '...'})` compiles to a sequential scan with
  `Filter: (properties @> '{"id":...}'::agtype)` because the only indexes on the
  AGE vertex tables are the internal `*_pkey` on the graphid column. The topology
  and MTR ingest paths run these MERGE/MATCH statements per link/hop (the
  `ag_catalog.cypher(...)` wrapper was the single largest live driver of demo
  CNPG CPU at ~20% of database time), so every one full-scans the vertex heap.

  - GIN(properties) satisfies the `properties @> '{"id":...}'` containment qual
    that AGE generates for `MERGE`/`MATCH (Label {id: '...'})`.
  - A btree over `agtype_access_operator(properties, '"device_id"')` satisfies the
    `WHERE a.device_id = '...'` equality qual used by the pruning / canonical
    rebuild paths on `Interface`.

  Built `CONCURRENTLY` (no long lock) and `IF NOT EXISTS` (idempotent). Purely
  additive: no query or application change, results unchanged.
  """

  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute(
      ~s|CREATE INDEX CONCURRENTLY IF NOT EXISTS device_properties_gin ON platform_graph."Device" USING gin (properties)|
    )

    execute(
      ~s|CREATE INDEX CONCURRENTLY IF NOT EXISTS interface_properties_gin ON platform_graph."Interface" USING gin (properties)|
    )

    execute(
      ~s|CREATE INDEX CONCURRENTLY IF NOT EXISTS mtrhop_properties_gin ON platform_graph."MtrHop" USING gin (properties)|
    )

    execute(
      ~s|CREATE INDEX CONCURRENTLY IF NOT EXISTS interface_device_id_btree ON platform_graph."Interface" USING btree ((ag_catalog.agtype_access_operator(VARIADIC ARRAY[properties, '"device_id"'::agtype])))|
    )
  end

  def down do
    execute(~s|DROP INDEX CONCURRENTLY IF EXISTS platform_graph.interface_device_id_btree|)
    execute(~s|DROP INDEX CONCURRENTLY IF EXISTS platform_graph.mtrhop_properties_gin|)
    execute(~s|DROP INDEX CONCURRENTLY IF EXISTS platform_graph.interface_properties_gin|)
    execute(~s|DROP INDEX CONCURRENTLY IF EXISTS platform_graph.device_properties_gin|)
  end
end
