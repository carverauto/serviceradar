defmodule ServiceRadar.Inventory.DeviceMetadataMergeTest do
  @moduledoc """
  `ocsf_devices.metadata` has many independent writers, each owning a disjoint set
  of keys. These tests pin the property that makes that safe: a write carries only
  its own keys, and the merge happens in the database.

  The failure being guarded is silent. A whole-map read-modify-write commits
  without error and without a log line, and the only evidence is a key that
  quietly went back to an older value -- which is why it survived long enough to
  block a remediation pass.
  """
  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.SyncIngestor

  require Ash.Query

  setup do
    {:ok, actor: SystemActor.system(:device_metadata_merge_test)}
  end

  @tag :visibility
  test "a writer holding a stale record cannot erase another writer's key", %{actor: actor} do
    ip = unique_ip()
    device = seed_device(actor, ip)

    # `stale` is this writer's snapshot, taken BEFORE the other writer commits --
    # exactly the shape of a job that preloads devices and then loops over them.
    stale = device

    {:ok, _} =
      device
      |> Ash.Changeset.for_update(:merge_metadata, %{metadata_patch: %{"other_writer" => "b"}})
      |> Ash.update(actor: actor)

    {:ok, _} =
      stale
      |> Ash.Changeset.for_update(:merge_metadata, %{metadata_patch: %{"stale_writer" => "c"}})
      |> Ash.update(actor: actor)

    metadata = reload_metadata(actor, ip)

    assert metadata["other_writer"] == "b",
           """
           LOST UPDATE: the stale writer erased a key it does not own.
           This is what a whole-map read-modify-write does, silently.
             metadata: #{inspect(metadata)}
           """

    assert metadata["stale_writer"] == "c"
    assert metadata["seed_key"] == "a", "the merge dropped a pre-existing key"
  end

  @tag :visibility
  test "merging overwrites only the keys the patch names", %{actor: actor} do
    ip = unique_ip()
    device = seed_device(actor, ip)

    {:ok, _} =
      device
      |> Ash.Changeset.for_update(:merge_metadata, %{
        metadata_patch: %{"seed_key" => "replaced", "added" => "new"}
      })
      |> Ash.update(actor: actor)

    metadata = reload_metadata(actor, ip)

    assert metadata["seed_key"] == "replaced"
    assert metadata["added"] == "new"
  end

  @tag :visibility
  test "an atom-keyed patch merges as the string key jsonb already stores", %{actor: actor} do
    ip = unique_ip()
    device = seed_device(actor, ip)

    {:ok, _} =
      device
      |> Ash.Changeset.for_update(:merge_metadata, %{metadata_patch: %{seed_key: "via_atom"}})
      |> Ash.update(actor: actor)

    metadata = reload_metadata(actor, ip)

    assert metadata["seed_key"] == "via_atom",
           "an atom key merged as a SECOND key instead of replacing the string one"

    refute Map.has_key?(metadata, :seed_key)
  end

  @tag :visibility
  test "an empty patch is a no-op rather than a wipe", %{actor: actor} do
    ip = unique_ip()
    device = seed_device(actor, ip)

    {:ok, _} =
      device
      |> Ash.Changeset.for_update(:merge_metadata, %{metadata_patch: %{}})
      |> Ash.update(actor: actor)

    assert reload_metadata(actor, ip)["seed_key"] == "a"
  end

  defp seed_device(actor, ip) do
    integration_id = "mm-#{System.unique_integer([:positive])}"

    assert :ok =
             SyncIngestor.ingest_updates(
               [
                 %{
                   "ip" => ip,
                   "mac" => unique_mac(),
                   "source" => "armis",
                   "metadata" => %{
                     "integration_id" => integration_id,
                     "integration_type" => "armis",
                     "armis_device_id" => integration_id,
                     "seed_key" => "a"
                   }
                 }
               ],
               actor: actor
             )

    fetch_device(actor, ip)
  end

  defp fetch_device(actor, ip) do
    query = Ash.Query.filter(Device, ip == ^ip)
    assert {:ok, result} = Ash.read(query, actor: actor)

    devices =
      case result do
        %Ash.Page.Keyset{results: rows} -> rows
        rows when is_list(rows) -> rows
      end

    assert [device | _] = devices
    device
  end

  defp reload_metadata(actor, ip), do: fetch_device(actor, ip).metadata || %{}

  defp unique_ip do
    fn -> System.unique_integer([:positive, :monotonic]) end
    |> Stream.repeatedly()
    |> Enum.find_value(fn n ->
      ip = "10.#{rem(div(n, 65_025), 250) + 1}.#{rem(div(n, 255), 250) + 1}.#{rem(n, 250) + 1}"

      case ServiceRadar.Repo.query("SELECT 1 FROM platform.ocsf_devices WHERE ip = $1 LIMIT 1", [
             ip
           ]) do
        {:ok, %{rows: []}} -> ip
        _ -> nil
      end
    end)
  end

  defp unique_mac do
    [:positive]
    |> System.unique_integer()
    |> Integer.to_string(16)
    |> String.pad_leading(10, "0")
    |> String.upcase()
    |> String.graphemes()
    |> Enum.chunk_every(2)
    |> Enum.map_join(":", &Enum.join/1)
    |> then(&("A8:" <> &1))
  end
end
