defmodule ServiceRadar.Inventory.Sync.MacVendorTest do
  @moduledoc """
  The OUI tier must never write a vendor it cannot justify.

  Two failure modes it exists to prevent, both cheap to reintroduce:
  attributing a randomised MAC to whoever owns the prefix it imitates, and
  letting an inference outrank a vendor a source actually reported.
  """
  use ExUnit.Case, async: true

  alias ServiceRadar.Inventory.Sync.MacVendor

  describe "locally administered addresses are never looked up" do
    test "a randomised MAC yields no prefix even when its prefix is registered" do
      # F692BF is the locally administered form of Ubiquiti's registered
      # F492BF -- they differ only in bit 1 of the first octet, and farm01 has
      # exactly this pair today. A lookup without the bit test returns
      # "Ubiquiti Inc" for a device that merely imitated the address.
      assert MacVendor.prefix_for("F492BF75C72B") != []
      assert MacVendor.prefix_for("F692BF75C721") == []
    end

    test "the whole locally-administered boundary is refused" do
      # Bit 1 of the first octet: the first octet ends in 2, 6, A or E.
      for octet <- ["02", "06", "0A", "0E", "AA", "FE"] do
        assert MacVendor.prefix_for(octet <> "1122334455") == [],
               "#{octet} is locally administered and must not be looked up"
      end

      for octet <- ["00", "04", "08", "1C", "B8", "FC"] do
        assert MacVendor.prefix_for(octet <> "1122334455") != [],
               "#{octet} is universal and must be looked up"
      end
    end

    test "resolve refuses a randomised MAC even if the lookup happens to hold its prefix" do
      # Belt and braces: prefix_for gates, but resolve must not be usable as a
      # way around it.
      lookup = %{0xF692BF => "Should Never Be Used"}
      assert MacVendor.resolve("F692BF75C721", lookup) == nil
    end
  end

  describe "resolution" do
    test "returns the organisation and the prefix that produced it" do
      lookup = %{0x1CB3C9 => "Apple, Inc."}
      assert {"Apple, Inc.", "1CB3C9"} = MacVendor.resolve("1CB3C9126C6C", lookup)
    end

    test "pads a low prefix so the recorded hex is always six characters" do
      # 0x000445 renders as "445" without padding, which matches nothing in the
      # registry and reads as a different prefix entirely.
      lookup = %{0x000445 => "LMS Skalar Instruments GmbH"}
      assert {_org, "000445"} = MacVendor.resolve("000445AABBCC", lookup)
    end

    test "an unknown prefix resolves to nothing rather than a guess" do
      assert MacVendor.resolve("1CB3C9126C6C", %{}) == nil
    end

    test "accepts separator forms and is case insensitive" do
      lookup = %{0x1CB3C9 => "Apple, Inc."}
      assert {"Apple, Inc.", _} = MacVendor.resolve("1c:b3:c9:12:6c:6c", lookup)
      assert {"Apple, Inc.", _} = MacVendor.resolve("1C-B3-C9-12-6C-6C", lookup)
    end

    test "nil and malformed input are refused" do
      assert MacVendor.resolve(nil, %{}) == nil
      assert MacVendor.resolve("not-a-mac", %{}) == nil
      assert MacVendor.prefix_for(nil) == []
      assert MacVendor.prefix_for("") == []
    end
  end

  describe "provenance" do
    test "records the source, prefix and dataset snapshot" do
      metadata =
        MacVendor.put_provenance(%{"existing" => "kept"}, {"Apple, Inc.", "1CB3C9"}, "snap-1")

      assert metadata["mac_vendor"] == "Apple, Inc."
      # Same string FlowEnrichment writes for flows, so one value means one
      # thing across the system.
      assert metadata["mac_vendor_source"] == "ieee_oui"
      assert metadata["mac_vendor_oui_prefix"] == "1CB3C9"
      assert metadata["mac_vendor_oui_snapshot_id"] == "snap-1"
      assert metadata["existing"] == "kept", "unrelated metadata must survive"
    end

    test "a device that no longer resolves loses its stale attribution" do
      # device_writes merges metadata with jsonb `||`, which is shallow and
      # lets incoming keys win -- so a key that simply stops being written
      # would persist forever. Stripping on every pass is what prevents a
      # vendor from outliving the MAC that justified it.
      stale = %{
        "mac_vendor" => "Apple, Inc.",
        "mac_vendor_source" => "ieee_oui",
        "mac_vendor_oui_prefix" => "1CB3C9",
        "keep" => "me"
      }

      metadata = MacVendor.put_provenance(stale, nil, "snap-2")

      refute Map.has_key?(metadata, "mac_vendor")
      refute Map.has_key?(metadata, "mac_vendor_source")
      refute Map.has_key?(metadata, "mac_vendor_oui_prefix")
      assert metadata["keep"] == "me"
    end

    test "omits the snapshot rather than writing a null one" do
      metadata = MacVendor.put_provenance(%{}, {"Apple, Inc.", "1CB3C9"}, nil)
      refute Map.has_key?(metadata, "mac_vendor_oui_snapshot_id")
      assert metadata["mac_vendor"] == "Apple, Inc."
    end

    test "every key this module writes is in the list device_writes strips" do
      # If these drift apart, a key stops being cleared on upsert and a stale
      # attribution becomes permanent. Pin them together.
      written =
        %{}
        |> MacVendor.put_provenance({"Apple, Inc.", "1CB3C9"}, "snap-1")
        |> Map.keys()

      owned = MacVendor.metadata_keys() ++ ["mac_vendor"]

      for key <- written do
        assert key in owned, "#{key} is written but not owned/stripped by MacVendor"
      end
    end
  end

  describe "bulk_lookup" do
    test "an empty or fully-randomised batch does no query at all" do
      assert {%{}, nil} = MacVendor.bulk_lookup([])
      # Every one of these is locally administered, so there is nothing to ask
      # the database about.
      assert {%{}, nil} = MacVendor.bulk_lookup(["021122334455", "0A1122334455", nil])
    end
  end

  describe "put_provenance/3 snapshot id normalization" do
    # Postgrex returns a `uuid` column as a RAW 16-byte binary. It used to be
    # passed through untouched because it satisfies is_binary/1, and the raw
    # bytes reached device metadata -- where the next jsonb encode blew up with
    # "invalid byte 0xFF" and took the entire bulk device upsert with it.
    # Asserting on Jason.encode is the point: a string comparison alone would
    # still have passed for a value that cannot be persisted.
    @raw_uuid <<255, 130, 164, 63, 110, 144, 71, 200, 161, 38, 10, 117, 161, 210, 52, 217>>
    @printable "ff82a43f-6e90-47c8-a126-0a75a1d234d9"

    test "a raw 16-byte uuid is normalized to printable form and stays encodable" do
      metadata = MacVendor.put_provenance(%{}, {"Example Corp", "F492BF"}, @raw_uuid)

      assert metadata["mac_vendor_oui_snapshot_id"] == @printable
      assert {:ok, _json} = Jason.encode(metadata)
    end

    test "an already-printable uuid is preserved" do
      metadata = MacVendor.put_provenance(%{}, {"Example Corp", "F492BF"}, @printable)

      assert metadata["mac_vendor_oui_snapshot_id"] == @printable
      assert {:ok, _json} = Jason.encode(metadata)
    end

    test "a printable non-uuid id is preserved, since the hazard is unencodable bytes" do
      metadata = MacVendor.put_provenance(%{}, {"Example Corp", "F492BF"}, "snap-1")

      assert metadata["mac_vendor_oui_snapshot_id"] == "snap-1"
      assert {:ok, _json} = Jason.encode(metadata)
    end

    test "an unencodable binary that is not a uuid is dropped rather than persisted" do
      metadata = MacVendor.put_provenance(%{}, {"Example Corp", "F492BF"}, <<255, 254, 253>>)

      refute Map.has_key?(metadata, "mac_vendor_oui_snapshot_id")
      assert {:ok, _json} = Jason.encode(metadata)
    end

    test "nil snapshot id is omitted" do
      metadata = MacVendor.put_provenance(%{}, {"Example Corp", "F492BF"}, nil)

      refute Map.has_key?(metadata, "mac_vendor_oui_snapshot_id")
    end
  end
end
