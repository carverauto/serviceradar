defmodule ServiceRadar.NetworkDiscovery.WorldSnapshotsTest do
  use ExUnit.Case, async: true

  alias AshPostgres.MigrationGenerator
  alias ServiceRadar.NetworkDiscovery
  alias ServiceRadar.NetworkDiscovery.WorldHead
  alias ServiceRadar.NetworkDiscovery.WorldLayout
  alias ServiceRadar.NetworkDiscovery.WorldPosition
  alias ServiceRadar.NetworkDiscovery.WorldRelation
  alias ServiceRadar.Repo

  @moduletag :db_free
  @resources [WorldHead, WorldLayout, WorldPosition, WorldRelation]
  @snapshot_root Path.expand("../../../priv/resource_snapshots/repo", __DIR__)
  @snapshot_paths Path.wildcard(Path.join(@snapshot_root, "platform.topology_world_*/*.json"))

  for path <- @snapshot_paths do
    @external_resource path
  end

  test "committed world snapshots match the pinned AshPostgres schema" do
    current = MigrationGenerator.take_snapshots(NetworkDiscovery, Repo, @resources)

    committed =
      Enum.map(@resources, fn resource ->
        directory = "platform." <> AshPostgres.DataLayer.Info.table(resource)

        @snapshot_paths
        |> Enum.filter(&(Path.basename(Path.dirname(&1)) == directory))
        |> Enum.max(fn -> flunk("Missing committed snapshot for #{directory}") end)
        |> File.read!()
        |> Jason.decode!(keys: :atoms!)
      end)

    assert [] == MigrationGenerator.get_operations_from_snapshots(committed, current)
  end
end
