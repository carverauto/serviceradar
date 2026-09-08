defmodule ServiceRadar.Inventory.DeviceFactsTest do
  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.CompositeChecks.CompositeCheckInput
  alias ServiceRadar.CompositeChecks.Resolvers.DeviceMetadata
  alias ServiceRadar.Inventory.Changes.MergeDeviceFacts
  alias ServiceRadar.Inventory.Device

  defp actor, do: SystemActor.system(:device_facts_test)

  defp device! do
    uid = "sr:" <> Ecto.UUID.generate()
    <<a, b, c, _rest::binary>> = :crypto.hash(:sha256, uid)

    Device
    |> Ash.Changeset.for_create(:create, %{
      uid: uid,
      hostname: "facts-#{a}-#{b}",
      ip: "10.#{a}.#{b}.#{max(c, 1)}"
    })
    |> Ash.create!(actor: actor())
  end

  defp write(device, facts) do
    device
    |> Ash.Changeset.for_update(:write_facts, %{facts: facts}, actor: actor())
    |> Ash.update()
  end

  setup do
    %{device: device!()}
  end

  test "writes the plain value and server-stamped provenance", %{device: device} do
    assert {:ok, updated} = write(device, %{"nac_applied" => true})

    assert updated.metadata["nac_applied"] == true

    provenance = updated.metadata[DeviceMetadata.provenance_key()]["nac_applied"]
    assert is_binary(provenance["updated_at"])
    assert {:ok, _dt, _} = DateTime.from_iso8601(provenance["updated_at"])
    assert is_binary(provenance["source"])
  end

  test "preserves unrelated metadata and earlier facts", %{device: device} do
    {:ok, device} = write(device, %{"first" => true})
    {:ok, device} = write(device, %{"second" => false})

    assert device.metadata["first"] == true
    assert device.metadata["second"] == false

    provenance = device.metadata[DeviceMetadata.provenance_key()]
    assert Map.has_key?(provenance, "first")
    assert Map.has_key?(provenance, "second")
  end

  test "a caller-supplied timestamp is ignored", %{device: device} do
    before = DateTime.utc_now()

    {:ok, updated} =
      write(device, %{"nac_applied" => true, "updated_at" => "1999-01-01T00:00:00Z"})

    {:ok, stamped, _} =
      updated.metadata
      |> get_in([DeviceMetadata.provenance_key(), "nac_applied", "updated_at"])
      |> DateTime.from_iso8601()

    assert DateTime.compare(stamped, before) in [:gt, :eq]
  end

  test "rejects an invalid key and writes nothing", %{device: device} do
    assert {:error, error} = write(device, %{"NacApplied" => true})
    assert Exception.message(error) =~ "NacApplied"

    {:ok, reloaded} = Device.get_by_uid(device.uid, false, actor: actor())
    refute Map.has_key?(reloaded.metadata, "NacApplied")
  end

  test "one invalid fact rejects the whole request", %{device: device} do
    assert {:error, _} = write(device, %{"good_key" => true, "BadKey" => false})

    {:ok, reloaded} = Device.get_by_uid(device.uid, false, actor: actor())
    refute Map.has_key?(reloaded.metadata, "good_key")
  end

  test "rejects a non-scalar value", %{device: device} do
    assert {:error, error} = write(device, %{"nested" => %{"a" => 1}})
    assert Exception.message(error) =~ "scalar"

    assert {:error, _} = write(device, %{"listy" => [1, 2]})
  end

  test "accepts booleans, numbers, and strings", %{device: device} do
    assert {:ok, updated} =
             write(device, %{"flag" => true, "count" => 3, "label" => "compliant"})

    assert updated.metadata["flag"] == true
    assert updated.metadata["count"] == 3
    assert updated.metadata["label"] == "compliant"
  end

  test "rejects a reserved key", %{device: device} do
    assert {:error, error} = write(device, %{"passive_fingerprint" => true})
    assert Exception.message(error) =~ "reserved"

    for key <- MergeDeviceFacts.reserved_keys() do
      assert {:error, _} = write(device, %{key => true})
    end
  end

  test "rejects writing the provenance key directly", %{device: device} do
    assert {:error, error} = write(device, %{DeviceMetadata.provenance_key() => true})
    assert Exception.message(error) =~ "reserved"
  end

  test "rejects an empty fact set", %{device: device} do
    assert {:error, error} = write(device, %{})
    assert Exception.message(error) =~ "at least one fact"
  end

  test "enforces the per-device fact cap", %{device: device} do
    cap = MergeDeviceFacts.max_facts()
    facts = Map.new(1..cap, fn i -> {"fact_#{i}", true} end)
    assert {:ok, device} = write(device, facts)

    assert {:error, error} = write(device, %{"one_too_many" => true})
    assert Exception.message(error) =~ "cap"
  end

  test "overwriting an existing fact does not count against the cap", %{device: device} do
    cap = MergeDeviceFacts.max_facts()
    facts = Map.new(1..cap, fn i -> {"fact_#{i}", true} end)
    {:ok, device} = write(device, facts)

    assert {:ok, updated} = write(device, %{"fact_1" => false})
    assert updated.metadata["fact_1"] == false
  end

  # The one cross-module contract that fails silently if broken: a mismatch on
  # the provenance key means every fact resolves unknown forever, with no error
  # anywhere.
  test "a written fact resolves as fresh through the composite resolver", %{device: device} do
    {:ok, updated} = write(device, %{"nac_applied" => true})

    input = %CompositeCheckInput{
      key: "nac",
      kind: :device_metadata,
      config: %{"path" => "nac_applied", "value_type" => "boolean", "max_age_seconds" => 3_600}
    }

    assert %{value: true, stale: false} =
             DeviceMetadata.resolve(input, updated.metadata, DateTime.utc_now())
  end

  test "a fact written long ago resolves stale through the composite resolver", %{device: device} do
    {:ok, updated} = write(device, %{"nac_applied" => true})

    input = %CompositeCheckInput{
      key: "nac",
      kind: :device_metadata,
      config: %{"path" => "nac_applied", "value_type" => "boolean", "max_age_seconds" => 60}
    }

    later = DateTime.add(DateTime.utc_now(), 3_600, :second)

    assert %{value: :unknown, reason: :stale} =
             DeviceMetadata.resolve(input, updated.metadata, later)
  end
end
