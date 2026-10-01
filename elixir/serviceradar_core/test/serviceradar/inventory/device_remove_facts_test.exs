defmodule ServiceRadar.Inventory.DeviceRemoveFactsTest do
  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.CompositeChecks.Resolvers.DeviceMetadata
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Repo

  defp actor, do: SystemActor.system(:device_remove_facts_test)

  defp device! do
    unique = System.unique_integer([:positive])

    Device
    |> Ash.Changeset.for_create(:create, %{
      uid: "sr:remove-facts-#{unique}",
      hostname: "remove-facts-#{unique}.test"
    })
    |> Ash.create!(actor: actor())
  end

  defp write(device, facts) do
    device
    |> Ash.Changeset.for_update(:write_facts, %{facts: facts}, actor: actor())
    |> Ash.update()
  end

  defp remove(device, keys) do
    device
    |> Ash.Changeset.for_update(:remove_facts, %{keys: keys}, actor: actor())
    |> Ash.update()
  end

  setup do
    %{device: device!()}
  end

  test "removes an existing fact and its provenance entry", %{device: device} do
    {:ok, device} = write(device, %{"example_fact" => true})
    assert device.metadata["example_fact"] == true
    assert Map.has_key?(device.metadata[DeviceMetadata.provenance_key()], "example_fact")

    assert {:ok, updated} = remove(device, ["example_fact"])

    refute Map.has_key?(updated.metadata, "example_fact")
    refute Map.has_key?(updated.metadata[DeviceMetadata.provenance_key()] || %{}, "example_fact")
  end

  test "removing a missing key is a no-op", %{device: device} do
    {:ok, device} = write(device, %{"example_fact" => true})

    assert {:ok, updated} = remove(device, ["never_written"])

    assert updated.metadata["example_fact"] == true
    assert Map.has_key?(updated.metadata[DeviceMetadata.provenance_key()], "example_fact")
  end

  test "non-fact metadata is untouched when removing a fact", %{device: device} do
    Repo.query!(
      """
      UPDATE platform.ocsf_devices
      SET metadata = COALESCE(metadata, '{}'::jsonb) || '{"integration_key": "preserved"}'::jsonb
      WHERE uid = $1
      """,
      [device.uid]
    )

    {:ok, device} = Device.get_by_uid(device.uid, false, actor: actor())

    {:ok, device} = write(device, %{"example_fact" => true})

    assert {:ok, updated} = remove(device, ["example_fact"])

    assert updated.metadata["integration_key"] == "preserved"
    refute Map.has_key?(updated.metadata, "example_fact")
  end

  test "removes only the specified keys, preserving other facts", %{device: device} do
    {:ok, device} = write(device, %{"fact_a" => true, "fact_b" => false})

    assert {:ok, updated} = remove(device, ["fact_a"])

    refute Map.has_key?(updated.metadata, "fact_a")
    refute Map.has_key?(updated.metadata[DeviceMetadata.provenance_key()] || %{}, "fact_a")
    assert updated.metadata["fact_b"] == false
    assert Map.has_key?(updated.metadata[DeviceMetadata.provenance_key()], "fact_b")
  end

  test "rejects removing a fact written by a different source", %{device: device} do
    {:ok, device} = write(device, %{"example_fact" => true})

    other_actor = SystemActor.system(:other_test_component)

    result =
      device
      |> Ash.Changeset.for_update(:remove_facts, %{keys: ["example_fact"]}, actor: other_actor)
      |> Ash.update()

    assert {:error, error} = result
    assert Exception.message(error) =~ "different source"
  end

  test "rejects the reserved provenance key", %{device: device} do
    assert {:error, error} = remove(device, [DeviceMetadata.provenance_key()])
    assert Exception.message(error) =~ "reserved"
  end

  test "rejects an invalid key format", %{device: device} do
    assert {:error, error} = remove(device, ["InvalidKey"])
    assert Exception.message(error) =~ "InvalidKey"
  end

  test "rejects an empty keys list", %{device: device} do
    assert {:error, error} = remove(device, [])
    assert Exception.message(error) =~ "at least one key"
  end

  test "unauthorized caller is denied", %{device: device} do
    {:ok, device} = write(device, %{"example_fact" => true})

    # nil actor has no permissions and should be forbidden.
    result =
      device
      |> Ash.Changeset.for_update(:remove_facts, %{keys: ["example_fact"]}, actor: nil)
      |> Ash.update()

    assert {:error, _error} = result
  end

  test "the remove is atomic: concurrent metadata writes are preserved", %{device: device} do
    {:ok, device} = write(device, %{"example_fact" => true})

    Repo.query!(
      """
      UPDATE platform.ocsf_devices
      SET metadata = COALESCE(metadata, '{}'::jsonb) || '{"concurrent_key": "kept"}'::jsonb
      WHERE uid = $1
      """,
      [device.uid]
    )

    assert {:ok, updated} = remove(device, ["example_fact"])

    assert updated.metadata["concurrent_key"] == "kept"
    refute Map.has_key?(updated.metadata, "example_fact")
  end
end
