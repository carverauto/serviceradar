defmodule ServiceRadar.Inventory.IdentityReconcilerUnmergeTest do
  @moduledoc """
  Tests for device unmerge behavior.
  """

  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceIdentifier
  alias ServiceRadar.Inventory.IdentityReconciler
  alias ServiceRadar.Inventory.MergeAudit
  alias ServiceRadar.TestSupport

  require Ash.Query

  @moduletag :integration

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    actor = SystemActor.system(:identity_reconciler_unmerge_test)
    {:ok, actor: actor}
  end

  test "unmerge restores from-device and records audit entry", %{actor: actor} do
    {:ok, device_a} = create_device(actor, "canonical-device", "10.0.10.1")
    {:ok, device_b} = create_device(actor, "merged-device", "10.0.10.2")

    mac = "00AA#{mac_suffix()}#{mac_suffix()}"

    # Register MAC on device_b
    assert {:ok, _} = register_identifier(actor, device_b.uid, :mac, mac)

    # Merge device_b into device_a (with identifier details for later reassignment)
    assert :ok =
             IdentityReconciler.merge_devices(device_b.uid, device_a.uid,
               actor: actor,
               reason: "identifier_conflict",
               details: %{
                 identifiers: [%{type: :mac, value: mac}],
                 from_device_ip: "10.0.10.2",
                 from_device_hostname: "merged-device"
               }
             )

    # Verify device_b is gone
    assert {:error, _} = Device.get_by_uid(device_b.uid, false, actor: actor)

    {:ok, unrelated_split} = create_device(actor, "unrelated-split", "10.0.10.3")

    assert {:ok, _} =
             MergeAudit.record(
               %{
                 from_device_id: device_b.uid,
                 to_device_id: unrelated_split.uid,
                 reason: "unmerge",
                 source: "test"
               },
               actor: actor
             )

    # The newer unmerge audit is cooldown evidence, not the merge to reverse.
    assert :ok = IdentityReconciler.unmerge_device(device_b.uid, actor: actor)

    # Verify device_b is restored
    assert {:ok, restored} = Device.get_by_uid(device_b.uid, false, actor: actor)
    assert restored.uid == device_b.uid

    # Verify both the original merge audit and the compensating unmerge audit exist
    {:ok, audits} = MergeAudit.get_by_device(device_b.uid, actor: actor)
    assert Enum.any?(audits, &(&1.reason == "identifier_conflict"))
    assert Enum.any?(audits, &(&1.reason == "unmerge"))
  end

  describe "identifiers restored by an unmerge" do
    test "a conflict merge's unmerge restores the source's identifiers and never the survivor's",
         %{actor: actor} do
      {:ok, survivor} = create_device(actor, unique("survivor"), nil)
      {:ok, source} = create_device(actor, unique("source"), nil)

      survivor_mac = doc_mac()
      source_mac = doc_mac()
      source_agent = unique("agent")

      assert {:ok, _} = register_identifier(actor, survivor.uid, :mac, survivor_mac)
      assert {:ok, _} = register_identifier(actor, source.uid, :mac, source_mac)
      assert {:ok, _} = register_identifier(actor, source.uid, :agent_id, source_agent)

      # What merge_conflicting_devices/4 records: every match, both sides.
      assert :ok =
               IdentityReconciler.merge_devices(source.uid, survivor.uid,
                 actor: actor,
                 reason: "identifier_conflict",
                 details: %{
                   identifiers: [
                     %{type: :mac, value: survivor_mac, device_id: survivor.uid},
                     %{type: :mac, value: source_mac, device_id: source.uid}
                   ]
                 }
               )

      assert owners(actor, [survivor_mac, source_mac, source_agent]) ==
               %{
                 survivor_mac => survivor.uid,
                 source_mac => survivor.uid,
                 source_agent => survivor.uid
               }

      assert :ok = IdentityReconciler.unmerge_device(source.uid, actor: actor)

      # Exactly what the source owned when it was merged, including the identifier
      # the conflict never named; the survivor keeps its own MAC.
      assert owners(actor, [survivor_mac, source_mac, source_agent]) ==
               %{
                 survivor_mac => survivor.uid,
                 source_mac => source.uid,
                 source_agent => source.uid
               }

      assert %{"restored_identifiers_source" => "recorded"} = unmerge_details(actor, source.uid)
    end

    test "an unmerge restores the source's identifiers when the merge caller recorded none",
         %{actor: actor} do
      {:ok, survivor} = create_device(actor, unique("survivor"), nil)
      {:ok, source} = create_device(actor, unique("source"), nil)

      survivor_mac = doc_mac()
      source_mac = doc_mac()

      assert {:ok, _} = register_identifier(actor, survivor.uid, :mac, survivor_mac)
      assert {:ok, _} = register_identifier(actor, source.uid, :mac, source_mac)

      assert :ok =
               IdentityReconciler.merge_devices(source.uid, survivor.uid,
                 actor: actor,
                 reason: "identity_resolution"
               )

      assert :ok = IdentityReconciler.unmerge_device(source.uid, actor: actor)

      assert owners(actor, [survivor_mac, source_mac]) ==
               %{survivor_mac => survivor.uid, source_mac => source.uid}
    end

    test "a legacy conflict row restores only the matches that named the source",
         %{actor: actor} do
      {:ok, survivor} = create_device(actor, unique("survivor"), nil)
      {:ok, source} = create_device(actor, unique("source"), nil)

      survivor_mac = doc_mac()
      source_mac = doc_mac()

      assert {:ok, _} = register_identifier(actor, survivor.uid, :mac, survivor_mac)
      assert {:ok, _} = register_identifier(actor, survivor.uid, :mac, source_mac)

      legacy_merge!(actor, source, survivor, %{
        "identifiers" => [
          %{"type" => "mac", "value" => survivor_mac, "device_id" => survivor.uid},
          %{"type" => "mac", "value" => source_mac, "device_id" => source.uid}
        ]
      })

      assert :ok = IdentityReconciler.unmerge_device(source.uid, actor: actor)

      assert owners(actor, [survivor_mac, source_mac]) ==
               %{survivor_mac => survivor.uid, source_mac => source.uid}

      assert %{"restored_identifiers_source" => "legacy_conflict_matches"} =
               unmerge_details(actor, source.uid)
    end

    test "a legacy row that recorded no ownership moves nothing back", %{actor: actor} do
      {:ok, survivor} = create_device(actor, unique("survivor"), nil)
      {:ok, source} = create_device(actor, unique("source"), nil)

      survivor_mac = doc_mac()
      assert {:ok, _} = register_identifier(actor, survivor.uid, :mac, survivor_mac)

      # The registrar's shape: a map, which names no owner.
      legacy_merge!(actor, source, survivor, %{
        "identifiers" => %{"mac" => survivor_mac}
      })

      assert :ok = IdentityReconciler.unmerge_device(source.uid, actor: actor)
      assert owners(actor, [survivor_mac]) == %{survivor_mac => survivor.uid}

      assert %{"restored_identifiers_source" => "unrecorded", "restored_identifiers" => []} =
               unmerge_details(actor, source.uid)
    end
  end

  test "unmerge returns error when no merge audit exists", %{actor: actor} do
    fake_device_id = "sr:" <> Ecto.UUID.generate()

    assert {:error, :no_merge_audit_found} =
             IdentityReconciler.unmerge_device(fake_device_id, actor: actor)
  end

  defp create_device(actor, hostname, ip) do
    attrs = %{
      uid: "sr:" <> Ecto.UUID.generate(),
      hostname: hostname,
      ip: ip
    }

    Device
    |> Ash.Changeset.for_create(:create, attrs)
    |> Ash.create(actor: actor)
  end

  defp register_identifier(actor, device_id, type, value) do
    attrs = %{
      device_id: device_id,
      identifier_type: type,
      identifier_value: value,
      partition: "default",
      source: "test"
    }

    DeviceIdentifier
    |> Ash.Changeset.for_create(:register, attrs)
    |> Ash.create(actor: actor)
  end

  # A merge_audit row written before merges recorded `source_identifiers`: the
  # source is tombstoned as a merge, and its identifiers already sit on the survivor.
  defp legacy_merge!(actor, source, survivor, details) do
    assert {:ok, _} =
             MergeAudit.record(
               %{
                 from_device_id: source.uid,
                 to_device_id: survivor.uid,
                 reason: "identifier_conflict",
                 source: "legacy",
                 details: details
               },
               actor: actor
             )

    assert {:ok, _} = Device.soft_delete(source, "merged", "identity_reconciler", actor: actor)
  end

  defp owners(actor, values) do
    DeviceIdentifier
    |> Ash.Query.filter(identifier_value in ^values)
    |> Ash.read!(actor: actor)
    |> Map.new(&{&1.identifier_value, &1.device_id})
  end

  defp unmerge_details(actor, device_uid) do
    MergeAudit
    |> Ash.Query.filter(to_device_id == ^device_uid and reason == "unmerge")
    |> Ash.read!(actor: actor)
    |> case do
      [%MergeAudit{details: details}] -> details
      other -> flunk("expected one unmerge row for #{device_uid}, got #{inspect(other)}")
    end
  end

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  # Documentation-range MAC (00:00:5E:00:53:xx), normalized as stored.
  defp doc_mac, do: "00005E0053" <> mac_suffix()

  defp mac_suffix do
    [:positive]
    |> System.unique_integer()
    |> rem(256)
    |> Integer.to_string(16)
    |> String.pad_leading(2, "0")
    |> String.upcase()
  end
end
