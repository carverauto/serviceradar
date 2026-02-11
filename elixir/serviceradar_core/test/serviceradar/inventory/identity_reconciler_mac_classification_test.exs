defmodule ServiceRadar.Inventory.IdentityReconcilerMacClassificationTest do
  @moduledoc """
  Tests for MAC address classification and confidence-gated merge behavior.
  """

  use ExUnit.Case, async: false

  @moduletag :integration

  require Ash.Query

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.{Device, DeviceIdentifier, IdentityReconciler}
  alias ServiceRadar.TestSupport

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    actor = SystemActor.system(:identity_reconciler_mac_classification_test)
    {:ok, actor: actor}
  end

  # ── MAC Classification ──

  describe "locally_administered_mac?/1" do
    test "identifies locally-administered MACs (bit 1 of first octet set)" do
      # 0x0E = 0b00001110, bit 1 is set
      assert IdentityReconciler.locally_administered_mac?("0EEA1432D278")
      # 0xF6 = 0b11110110, bit 1 is set
      assert IdentityReconciler.locally_administered_mac?("F692BF75C722")
      # 0xF4 = 0b11110100, bit 1 is set (yes, 0xF4 & 0x02 = 0x00, bit 1 is NOT set)
      # Actually: 0xF4 = 11110100, bit 1 (from LSB) = 0. Not locally administered.
      refute IdentityReconciler.locally_administered_mac?("F492BF75C722")
      # 0x02 = 0b00000010, bit 1 is set
      assert IdentityReconciler.locally_administered_mac?("020000000001")
      # 0x0A = 0b00001010, bit 1 is set
      assert IdentityReconciler.locally_administered_mac?("0A0000000001")
    end

    test "identifies globally-unique MACs (bit 1 of first octet clear)" do
      # 0x00 = 0b00000000
      refute IdentityReconciler.locally_administered_mac?("001122334455")
      # 0x0C = 0b00001100, bit 1 is clear
      refute IdentityReconciler.locally_administered_mac?("0CEA1432D278")
      # 0xF4 = 0b11110100, bit 1 is clear
      refute IdentityReconciler.locally_administered_mac?("F492BF75C722")
      # 0xAC = 0b10101100, bit 1 is clear
      refute IdentityReconciler.locally_administered_mac?("ACDE48000001")
    end

    test "handles nil and empty input" do
      refute IdentityReconciler.locally_administered_mac?(nil)
      refute IdentityReconciler.locally_administered_mac?("")
    end

    test "handles MAC with separators" do
      assert IdentityReconciler.locally_administered_mac?("0E:EA:14:32:D2:78")
      refute IdentityReconciler.locally_administered_mac?("0C:EA:14:32:D2:78")
    end
  end

  describe "mac_confidence/1" do
    test "returns :medium for locally-administered MACs" do
      assert IdentityReconciler.mac_confidence("0EEA1432D278") == :medium
      assert IdentityReconciler.mac_confidence("F692BF75C722") == :medium
    end

    test "returns :strong for globally-unique MACs" do
      assert IdentityReconciler.mac_confidence("001122334455") == :strong
      assert IdentityReconciler.mac_confidence("0CEA1432D278") == :strong
    end
  end

  # ── Confidence-gated merge ──

  describe "confidence-gated merge behavior" do
    test "locally-administered MAC registered with medium confidence", %{actor: actor} do
      {:ok, device} = create_device(actor, "test-la-mac")
      la_mac = "0EAA#{mac_suffix()}#{mac_suffix()}"

      ids = %{
        agent_id: nil,
        armis_id: nil,
        integration_id: nil,
        netbox_id: nil,
        mac: la_mac,
        ip: "",
        partition: "default"
      }

      assert :ok = IdentityReconciler.register_identifiers(device.uid, ids, actor: actor)

      # Verify it was registered with medium confidence
      query =
        DeviceIdentifier
        |> Ash.Query.for_read(:lookup, %{
          identifier_type: :mac,
          identifier_value: la_mac,
          partition: "default"
        })

      assert {:ok, [identifier]} = Ash.read(query, actor: actor)
      assert identifier.confidence == :medium
    end

    test "globally-unique MAC registered with strong confidence", %{actor: actor} do
      {:ok, device} = create_device(actor, "test-gu-mac")
      gu_mac = "00AA#{mac_suffix()}#{mac_suffix()}"

      ids = %{
        agent_id: nil,
        armis_id: nil,
        integration_id: nil,
        netbox_id: nil,
        mac: gu_mac,
        ip: "",
        partition: "default"
      }

      assert :ok = IdentityReconciler.register_identifiers(device.uid, ids, actor: actor)

      query =
        DeviceIdentifier
        |> Ash.Query.for_read(:lookup, %{
          identifier_type: :mac,
          identifier_value: gu_mac,
          partition: "default"
        })

      assert {:ok, [identifier]} = Ash.read(query, actor: actor)
      assert identifier.confidence == :strong
    end

    test "shared locally-administered MAC does not trigger merge", %{actor: actor} do
      {:ok, device_a} = create_device(actor, "la-mac-device-a")
      {:ok, device_b} = create_device(actor, "la-mac-device-b")

      # Use a locally-administered MAC (bit 1 of 0x0E is set)
      la_mac = "0E#{mac_suffix()}#{mac_suffix()}#{mac_suffix()}"

      # Register MAC for device A
      assert {:ok, _} = register_identifier(actor, device_a.uid, :mac, la_mac, :medium)

      # Now register the same MAC for device B — should NOT trigger merge
      ids = %{
        agent_id: nil,
        armis_id: nil,
        integration_id: nil,
        netbox_id: nil,
        mac: la_mac,
        ip: "",
        partition: "default"
      }

      IdentityReconciler.register_identifiers(device_b.uid, ids, actor: actor)

      # Both devices should still exist
      assert {:ok, _} = Device.get_by_uid(device_a.uid, false, actor: actor)
      assert {:ok, _} = Device.get_by_uid(device_b.uid, false, actor: actor)
    end

    test "shared globally-unique MAC triggers merge", %{actor: actor} do
      {:ok, device_a} = create_device(actor, "gu-mac-device-a")
      {:ok, device_b} = create_device(actor, "gu-mac-device-b")

      # Use a globally-unique MAC (bit 1 of 0x00 is clear)
      gu_mac = "00#{mac_suffix()}#{mac_suffix()}#{mac_suffix()}"

      # Register MAC for device A
      assert {:ok, _} = register_identifier(actor, device_a.uid, :mac, gu_mac, :strong)

      # Now register the same MAC for device B — should trigger merge
      ids = %{
        agent_id: nil,
        armis_id: nil,
        integration_id: nil,
        netbox_id: nil,
        mac: gu_mac,
        ip: "",
        partition: "default"
      }

      IdentityReconciler.register_identifiers(device_b.uid, ids, actor: actor)

      # One device should be merged into the other
      a_exists = match?({:ok, _}, Device.get_by_uid(device_a.uid, false, actor: actor))
      b_exists = match?({:ok, _}, Device.get_by_uid(device_b.uid, false, actor: actor))

      # Exactly one should survive
      assert a_exists or b_exists
      refute a_exists and b_exists,
             "Expected one device to be merged, but both still exist"
    end
  end

  defp create_device(actor, hostname) do
    attrs = %{
      uid: "sr:" <> Ecto.UUID.generate(),
      hostname: hostname,
      ip: "10.#{:rand.uniform(200)}.#{:rand.uniform(200)}.#{:rand.uniform(200)}"
    }

    Device
    |> Ash.Changeset.for_create(:create, attrs)
    |> Ash.create(actor: actor)
  end

  defp register_identifier(actor, device_id, type, value, confidence) do
    attrs = %{
      device_id: device_id,
      identifier_type: type,
      identifier_value: value,
      partition: "default",
      confidence: confidence,
      source: "test"
    }

    DeviceIdentifier
    |> Ash.Changeset.for_create(:register, attrs)
    |> Ash.create(actor: actor)
  end

  defp mac_suffix do
    System.unique_integer([:positive])
    |> rem(256)
    |> Integer.to_string(16)
    |> String.pad_leading(2, "0")
    |> String.upcase()
  end
end
