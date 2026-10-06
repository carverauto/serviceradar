defmodule ServiceRadar.Inventory.DeviceFactsTest do
  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.CompositeChecks.CompositeCheckInput
  alias ServiceRadar.CompositeChecks.Resolvers.DeviceMetadata
  alias ServiceRadar.Inventory.Changes.MergeDeviceFacts
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Repo

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
    {:ok, updated} =
      write(device, %{"nac_applied" => true, "updated_at" => "1999-01-01T00:00:00Z"})

    stamped = provenance_at(updated, "nac_applied")

    # The stamp is the database clock of the writing transaction, which under
    # the test sandbox is the test's own transaction start: bound it against
    # that clock rather than against an application clock read.
    assert abs(DateTime.diff(stamped, database_now(), :second)) < 60
  end

  # Composite checks select a device when its provenance updated_at is later
  # than a mark taken with the database now(). An application timestamp taken
  # before the write's transaction opened could fall behind that mark, so the
  # stamp must be the database clock at the writing statement.
  test "stamps provenance with the database clock of the writing transaction", %{device: device} do
    {:ok, {updated, transaction_now}} =
      Repo.transaction(fn ->
        transaction_now = database_now()
        # An application-side stamp would be at least this much later.
        Process.sleep(20)
        {:ok, updated} = write(device, %{"nac_applied" => true})
        {updated, transaction_now}
      end)

    assert DateTime.compare(provenance_at(updated, "nac_applied"), transaction_now) == :eq
  end

  # The facts write merges in the database. Writing a whole map computed from
  # the loaded record would silently revert a key another writer committed
  # after that record was read.
  test "keeps metadata another writer committed after the device was loaded", %{device: device} do
    Repo.query!(
      """
      UPDATE platform.ocsf_devices
      SET metadata = COALESCE(metadata, '{}'::jsonb) || '{"other_writer": "kept"}'::jsonb
      WHERE uid = $1
      """,
      [device.uid]
    )

    # `device` is the stale struct loaded before that write.
    assert {:ok, updated} = write(device, %{"nac_applied" => true})
    assert updated.metadata["other_writer"] == "kept"
    assert updated.metadata["nac_applied"] == true

    {:ok, reloaded} = Device.get_by_uid(device.uid, false, actor: actor())
    reloaded = if is_list(reloaded), do: hd(reloaded), else: reloaded
    assert reloaded.metadata["other_writer"] == "kept"
  end

  defp provenance_at(device, key) do
    {:ok, stamped, _offset} =
      device.metadata
      |> get_in([DeviceMetadata.provenance_key(), key, "updated_at"])
      |> DateTime.from_iso8601()

    DateTime.truncate(stamped, :microsecond)
  end

  defp database_now do
    %{rows: [[now]]} = Repo.query!("SELECT now()")
    DateTime.truncate(now, :microsecond)
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

  test "rejects the identity-bearing keys", %{device: device} do
    # Listed here rather than read from reserved_keys/0, so that a key dropped from the
    # reserved list fails this test instead of leaving the loop above one key shorter.
    for key <- ~w(armis_device_id integration_id mac ip hostname switch_port_attachment) do
      assert {:error, error} = write(device, %{key => "1001"})
      assert Exception.message(error) =~ "#{key} is reserved"
    end

    assert {:ok, reread} = Device.get_by_uid(device.uid, false, actor: actor())
    refute Map.has_key?(reread.metadata || %{}, "armis_device_id")
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

    later = DateTime.shift(DateTime.utc_now(), hour: 1)

    assert %{value: :unknown, reason: :stale} =
             DeviceMetadata.resolve(input, updated.metadata, later)
  end
end
