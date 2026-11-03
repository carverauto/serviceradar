defmodule ServiceRadar.Infrastructure.DefaultPartitionMigrationDbTest do
  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Repo
  alias ServiceRadar.Repo.Migrations.SeedDefaultPartition, as: Migration

  @migration_path Path.expand(
                    "../../../priv/repo/migrations/20261102231152_seed_default_partition.exs",
                    __DIR__
                  )
  @external_resource @migration_path

  Code.require_file(@migration_path)

  test "re-seeding keeps the one default partition an operator has edited" do
    %{num_rows: 1} =
      Repo.query!("""
      UPDATE platform.partitions
      SET name = 'Site Alpha', enabled = false, cidr_ranges = ARRAY['192.0.2.0/24']
      WHERE slug = 'default'
      """)

    Repo.query!(Migration.seed_sql("platform"))

    assert %{rows: [["Site Alpha", false, ["192.0.2.0/24"]]]} =
             Repo.query!("""
             SELECT name, enabled, cidr_ranges FROM platform.partitions WHERE slug = 'default'
             """)
  end
end
