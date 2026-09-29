defmodule ServiceRadarWebNG.Topology.WorldHealthSourceDBTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Repo
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.Topology.WorldHealthSource

  @moduletag :topology_atlas_db

  setup do
    :ok = Sandbox.checkout(Repo)
    %{scope: Scope.for_user(SystemActor.system(:world_health_source_test))}
  end

  test "health follows persisted availability and identity changes while missing and deleted devices stay unknown", %{
    scope: scope
  } do
    ready = create_device(scope, "sr:health-ready", true, %{})
    down = create_device(scope, "sr:health-down", false, %{"identity_source" => "inventory"})
    create_device(scope, "sr:health-unobserved", nil, %{})
    create_device(scope, "sr:health-no-metadata", true, nil)
    sighting = create_device(scope, "sr:health-sighting", true, %{"identity_source" => "mapper_topology_sighting"})

    ids = [ready.uid, down.uid, "sr:health-unobserved", "sr:health-no-metadata", sighting.uid, "sr:health-absent"]

    assert {:ok,
            [
              %{device_id: "sr:health-ready", state: :healthy},
              %{device_id: "sr:health-down", state: :unavailable},
              %{device_id: "sr:health-unobserved", state: :unknown},
              %{device_id: "sr:health-no-metadata", state: :healthy},
              %{device_id: "sr:health-sighting", state: :unknown},
              %{device_id: "sr:health-absent", state: :unknown}
            ]} = WorldHealthSource.fetch(ids)

    ready
    |> Ash.Changeset.for_update(:set_availability, %{is_available: false}, scope: scope)
    |> Ash.update!()

    sighting
    |> Ash.Changeset.for_update(:merge_metadata, %{metadata_patch: %{"identity_source" => "inventory"}}, scope: scope)
    |> Ash.update!()

    down
    |> Ash.Changeset.for_update(:soft_delete, %{deleted_reason: "synthetic health source test"}, scope: scope)
    |> Ash.update!()

    assert {:ok,
            [
              %{device_id: "sr:health-ready", state: :unavailable},
              %{device_id: "sr:health-down", state: :unknown},
              %{device_id: "sr:health-unobserved", state: :unknown},
              %{device_id: "sr:health-no-metadata", state: :healthy},
              %{device_id: "sr:health-sighting", state: :healthy},
              %{device_id: "sr:health-absent", state: :unknown}
            ]} = WorldHealthSource.fetch(ids)
  end

  test "a full bounded request preserves every identity and rejects overflow", %{scope: scope} do
    device = create_device(scope, "sr:health-final-member", true, %{})
    missing = Enum.map(1..499, &"sr:health-missing-#{&1}")
    ids = missing ++ [device.uid]

    assert {:ok, rows} = WorldHealthSource.fetch(ids)
    assert Enum.map(rows, & &1.device_id) == ids
    assert Enum.all?(Enum.take(rows, 499), &(&1.state == :unknown))
    assert List.last(rows) == %{device_id: device.uid, state: :healthy}
    assert {:error, :invalid_batch} = WorldHealthSource.fetch(ids ++ ["sr:health-overflow"])
    assert {:ok, []} = WorldHealthSource.fetch([])
  end

  defp create_device(scope, uid, available, metadata) do
    Device
    |> Ash.Changeset.for_create(:create, %{uid: uid, is_available: available, metadata: metadata}, scope: scope)
    |> Ash.create!()
  end
end
