defmodule ServiceRadar.Inventory.IdentityReconcilerMacValidationTest do
  @moduledoc """
  Unit tests for MAC identifier validation and normalization.

  Multi-value MAC fields (Armis emits comma-joined MAC histories) must be
  split into atomic, validated values; malformed values must never become
  identifiers. The legacy comma-joined blob value remains available for
  lookups only, bridging identifier rows written before validation existed.
  """

  use ExUnit.Case, async: true

  alias ServiceRadar.Inventory.IdentityReconciler
  alias ServiceRadar.Inventory.Sync.Lookups
  alias ServiceRadar.Inventory.Sync.Normalize

  describe "normalize_mac/1" do
    test "normalizes a single MAC with separators" do
      assert IdentityReconciler.normalize_mac("00:1a:a0:b9:40:40") == "001AA0B94040"
      assert IdentityReconciler.normalize_mac("00-1A-A0-B9-40-40") == "001AA0B94040"
      assert IdentityReconciler.normalize_mac("001a.a0b9.4040") == "001AA0B94040"
    end

    test "returns the first valid MAC from a comma-joined blob" do
      assert IdentityReconciler.normalize_mac("001AA0B94040,001422F42A2A,70B3D59EDC93") ==
               "001AA0B94040"
    end

    test "skips invalid entries and returns the first valid MAC" do
      assert IdentityReconciler.normalize_mac("garbage,00:14:22:F4:2A:2A") == "001422F42A2A"
    end

    test "rejects malformed values" do
      assert IdentityReconciler.normalize_mac("not-a-mac") == nil
      assert IdentityReconciler.normalize_mac("001AA0B940") == nil
      assert IdentityReconciler.normalize_mac("001AA0B94040FF") == nil
      assert IdentityReconciler.normalize_mac("") == nil
      assert IdentityReconciler.normalize_mac(nil) == nil
    end
  end

  describe "normalize_mac_list/1" do
    test "splits and normalizes a comma-joined blob" do
      assert IdentityReconciler.normalize_mac_list("001AA0B94040,00:14:22:F4:2A:2A") ==
               ["001AA0B94040", "001422F42A2A"]
    end

    test "supports semicolon and whitespace delimiters" do
      assert IdentityReconciler.normalize_mac_list("001AA0B94040; 001422F42A2A 70B3D59EDC93") ==
               ["001AA0B94040", "001422F42A2A", "70B3D59EDC93"]
    end

    test "drops invalid entries and dedupes preserving order" do
      assert IdentityReconciler.normalize_mac_list("junk,001AA0B94040,001AA0B94040,xx:yy") ==
               ["001AA0B94040"]
    end

    test "returns empty list for garbage-only or empty input" do
      assert IdentityReconciler.normalize_mac_list("garbage,more-garbage") == []
      assert IdentityReconciler.normalize_mac_list("") == []
      assert IdentityReconciler.normalize_mac_list(nil) == []
    end
  end

  describe "extract_strong_identifiers/1 MAC handling" do
    test "extracts atomic MACs and keeps the legacy blob for lookup only" do
      ids =
        IdentityReconciler.extract_strong_identifiers(%{
          device_id: nil,
          ip: "10.0.0.5",
          mac: "001AA0B94040,001422F42A2A",
          partition: "default",
          metadata: %{}
        })

      assert ids.mac == "001AA0B94040"
      assert ids.macs == ["001AA0B94040", "001422F42A2A"]
      assert ids.legacy_mac == "001AA0B94040,001422F42A2A"
    end

    test "single-MAC updates carry no legacy blob" do
      ids =
        IdentityReconciler.extract_strong_identifiers(%{
          device_id: nil,
          ip: nil,
          mac: "00:1A:A0:B9:40:40",
          partition: "default",
          metadata: %{}
        })

      assert ids.mac == "001AA0B94040"
      assert ids.macs == ["001AA0B94040"]
      assert ids.legacy_mac == nil
    end

    test "harvests mapper alt_mac metadata as additional identity MACs" do
      ids =
        IdentityReconciler.extract_strong_identifiers(%{
          device_id: nil,
          ip: "152.117.116.178",
          mac: "f4:92:bf:75:c7:21",
          partition: "default",
          metadata: %{"alt_mac:f692bf75c721" => "1"}
        })

      assert ids.mac == "F492BF75C721"
      assert ids.macs == ["F492BF75C721", "F692BF75C721"]
    end

    test "bulk identifier extraction looks up the hardware MAC sibling" do
      updates = [
        Normalize.normalize_update(%{
          "ip" => "192.168.1.1",
          "mac" => "f6:92:bf:75:c7:21",
          "source" => "mapper",
          "metadata" => %{"identity_mac_kind" => "primary"}
        })
      ]

      extracted = Lookups.extract_all_identifiers(updates)
      assert {:mac, "F692BF75C721", "default"} in extracted
      assert {:mac, "F492BF75C721", "default"} in extracted
    end

    test "consumes the metadata mac_addresses list emitted by the agent" do
      ids =
        IdentityReconciler.extract_strong_identifiers(%{
          device_id: nil,
          ip: nil,
          mac: "00:1A:A0:B9:40:40",
          partition: "default",
          metadata: %{"mac_addresses" => "001AA0B94040,001422F42A2A,70B3D59EDC93"}
        })

      assert ids.mac == "001AA0B94040"
      assert ids.macs == ["001AA0B94040", "001422F42A2A", "70B3D59EDC93"]
    end

    test "emits rejection telemetry when a non-empty MAC field has no valid value" do
      handler_id = "mac-validation-test-#{System.unique_integer([:positive])}"

      :ok =
        :telemetry.attach(
          handler_id,
          [:serviceradar, :identity_reconciler, :identifier, :rejected],
          fn event, measurements, metadata, pid ->
            send(pid, {:telemetry_event, event, measurements, metadata})
          end,
          self()
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      ids =
        IdentityReconciler.extract_strong_identifiers(%{
          device_id: nil,
          ip: nil,
          mac: "definitely-not-a-mac",
          partition: "default",
          metadata: %{}
        })

      assert ids.mac == nil
      assert ids.macs == []

      assert_received {:telemetry_event,
                       [:serviceradar, :identity_reconciler, :identifier, :rejected], %{count: 1},
                       %{identifier_type: :mac}}
    end
  end

  describe "mac_lookup_values/1" do
    test "returns atomic MACs first and the legacy blob last" do
      ids =
        IdentityReconciler.extract_strong_identifiers(%{
          device_id: nil,
          ip: nil,
          mac: "001AA0B94040,001422F42A2A",
          partition: "default",
          metadata: %{}
        })

      assert IdentityReconciler.mac_lookup_values(ids) ==
               ["001AA0B94040", "001422F42A2A", "001AA0B94040,001422F42A2A"]
    end
  end

  describe "generate_deterministic_device_id/1" do
    test "UID derives from the primary MAC, not the volatile MAC history" do
      base = %{device_id: nil, ip: nil, partition: "default", metadata: %{}}

      ids_a =
        IdentityReconciler.extract_strong_identifiers(
          Map.put(base, :mac, "001AA0B94040,001422F42A2A")
        )

      ids_b =
        IdentityReconciler.extract_strong_identifiers(
          Map.put(base, :mac, "001AA0B94040,70B3D59EDC93,ACDE48000001")
        )

      assert IdentityReconciler.generate_deterministic_device_id(ids_a) ==
               IdentityReconciler.generate_deterministic_device_id(ids_b)
    end

    test "different primary MACs produce different UIDs" do
      base = %{device_id: nil, ip: nil, partition: "default", metadata: %{}}

      ids_a = IdentityReconciler.extract_strong_identifiers(Map.put(base, :mac, "001AA0B94040"))
      ids_b = IdentityReconciler.extract_strong_identifiers(Map.put(base, :mac, "001422F42A2A"))

      refute IdentityReconciler.generate_deterministic_device_id(ids_a) ==
               IdentityReconciler.generate_deterministic_device_id(ids_b)
    end
  end
end
