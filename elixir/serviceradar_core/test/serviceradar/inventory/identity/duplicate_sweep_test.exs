defmodule ServiceRadar.Inventory.Identity.DuplicateSweepTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Inventory.Identity.DuplicateSweep

  describe "interface_mac_chassis_groups_from_rows/1" do
    test "pairs a chassis that reports another device's anchor MAC on its own interface" do
      # One chassis reached at two addresses becomes two device rows anchored by
      # DIFFERENT interface MACs (farm01: WAN ...C721, LAN ...C72B). They share no
      # identifier, so every other grouping here correctly finds nothing. The
      # evidence that they are one device is that one of them reports the other's
      # anchor MAC on its OWN interface table.
      rows = [{"F492BF75C721", "sr:lan-side", "sr:wan-side", "default"}]

      assert [{{"default", :interface_mac_chassis, "F492BF75C721"}, members}] =
               DuplicateSweep.interface_mac_chassis_groups_from_rows(rows)

      assert MapSet.equal?(members, MapSet.new(["sr:lan-side", "sr:wan-side"]))
    end

    test "never merges on a locally-administered interface MAC" do
      # tap/veth/dummy/bridge addresses are synthesised, not hardware. The writer
      # already refuses them; asserting it here too means the guarantee does not
      # depend on which rows the query happens to return.
      rows = [
        {"026E4E5C1314", "sr:host", "sr:guest", "default"},
        {"F692BF75C721", "sr:a", "sr:b", "default"},
        {"7A806C33A1F4", "sr:c", "sr:d", "default"}
      ]

      assert DuplicateSweep.interface_mac_chassis_groups_from_rows(rows) == []
    end

    test "collapses duplicate evidence for the same pair" do
      # A chassis reports many interfaces; several may match the same other
      # device. That is one pair, not several.
      rows = [
        {"F492BF75C721", "sr:lan", "sr:wan", "default"},
        {"F492BF75C721", "sr:lan", "sr:wan", "default"}
      ]

      assert [{{"default", :interface_mac_chassis, "F492BF75C721"}, _}] =
               DuplicateSweep.interface_mac_chassis_groups_from_rows(rows)
    end

    test "keeps universal and drops locally-administered in the same batch" do
      rows = [
        {"F492BF75C72B", "sr:keep-a", "sr:keep-b", "default"},
        {"026E4E5C1314", "sr:drop-a", "sr:drop-b", "default"}
      ]

      assert [{{"default", :interface_mac_chassis, "F492BF75C72B"}, members}] =
               DuplicateSweep.interface_mac_chassis_groups_from_rows(rows)

      assert MapSet.equal?(members, MapSet.new(["sr:keep-a", "sr:keep-b"]))
    end
  end

  describe "column_mac_groups_from_rows/1" do
    test "pairs devices only when the identifier owner still carries the same current MAC" do
      # device_identifiers is UNIQUE on (identifier_type, identifier_value,
      # partition), so a second device can never register the same MAC. Without
      # this grouping the two records stay split forever: duplicate-identifier
      # grouping cannot see them, and neither can the sibling grouping, which
      # needs both sides registered. The owner's current MAC must corroborate
      # the old identifier: a survivor may own many historical MAC identifiers
      # reassigned by earlier merges, and those must not pull unrelated devices
      # into its component.
      rows = [
        {"AC8BA9D587DD", "sr:column-side", "sr:identifier-owner", "default", "default", "default",
         "ac:8b:a9:d5:87:dd"}
      ]

      assert [{{"default", :mac_column, "AC8BA9D587DD"}, members}] =
               DuplicateSweep.column_mac_groups_from_rows(rows)

      assert MapSet.equal?(members, MapSet.new(["sr:column-side", "sr:identifier-owner"]))
    end

    test "never merges on a locally-administered MAC" do
      # Randomized phone Wi-Fi and virtual bridges are not globally unique;
      # merging on them would collapse unrelated hardware.
      rows = [
        {"1E14049215A9", "sr:a", "sr:b", "default", "default", "default", "1E14049215A9"},
        {"56FE96003BA7", "sr:c", "sr:d", "default", "default", "default", "56FE96003BA7"},
        {"A67C5557004F", "sr:e", "sr:f", "default", "default", "default", "A67C5557004F"}
      ]

      assert DuplicateSweep.column_mac_groups_from_rows(rows) == []
    end

    test "keeps globally-unique MACs and drops locally-administered ones in the same batch" do
      rows = [
        {"1CB3C9126C6C", "sr:keep-a", "sr:keep-b", "default", "default", "default",
         "1C:B3:C9:12:6C:6C"},
        {"C2AB756587EF", "sr:drop-a", "sr:drop-b", "default", "default", "default",
         "C2:AB:75:65:87:EF"}
      ]

      assert [{{"default", :mac_column, "1CB3C9126C6C"}, _}] =
               DuplicateSweep.column_mac_groups_from_rows(rows)
    end

    test "partitions scope the group key" do
      rows = [
        {"1CB3C9126C6C", "sr:a", "sr:b", "default", "default", "default", "1CB3C9126C6C"},
        {"1CB3C9126C6C", "sr:c", "sr:d", "tenant-2", "tenant-2", "tenant-2", "1CB3C9126C6C"}
      ]

      keys = rows |> DuplicateSweep.column_mac_groups_from_rows() |> Enum.map(&elem(&1, 0))

      assert {"default", :mac_column, "1CB3C9126C6C"} in keys
      assert {"tenant-2", :mac_column, "1CB3C9126C6C"} in keys
    end

    test "is empty for no rows" do
      assert DuplicateSweep.column_mac_groups_from_rows([]) == []
    end

    test "rejects an identifier that is only historical on its current owner" do
      rows = [
        {"0009EC028145", "sr:rids", "sr:unrelated-survivor", "default", "default", "default",
         "B8:A4:4F:7D:85:2C"}
      ]

      assert DuplicateSweep.column_mac_groups_from_rows(rows) == []
    end

    test "never merges a device across identifier partitions" do
      rows = [
        {"0009EC028145", "sr:rids", "sr:armis", "default", "default", "default:armis:source-a",
         "00:09:EC:02:81:45"}
      ]

      assert DuplicateSweep.column_mac_groups_from_rows(rows) == []
    end
  end

  describe "classify_duplicate_components/1" do
    test "keeps isolated pairs and blocks transitive components" do
      entries = [
        {{"default", :mac_column, "0009EC028145"}, MapSet.new(["sr:a", "sr:b"])},
        {{"default", :mac_column, "B8A44F7D852C"}, MapSet.new(["sr:b", "sr:c"])},
        {{"default", :mac_column, "001A2B000001"}, MapSet.new(["sr:d", "sr:e"])}
      ]

      assert %{mergeable: [pair], blocked: [component]} =
               DuplicateSweep.classify_duplicate_components(entries)

      assert pair.device_ids == ["sr:d", "sr:e"]
      assert component.device_ids == ["sr:a", "sr:b", "sr:c"]
      assert Enum.map(component.evidence, & &1.value) == ["0009EC028145", "B8A44F7D852C"]
    end

    test "blocks one evidence group that names more than two devices" do
      entries = [
        {{"default", :agent_id, "agent-1"}, MapSet.new(["sr:a", "sr:b", "sr:c"])}
      ]

      assert %{mergeable: [], blocked: [%{device_ids: ["sr:a", "sr:b", "sr:c"]}]} =
               DuplicateSweep.classify_duplicate_components(entries)
    end
  end

  describe "normalize_max_merges/1 and merge_cap_reached?/2" do
    test "nil from the job schedule is the default cap, not an Elixir or-crash" do
      cap = DuplicateSweep.normalize_max_merges(nil)
      assert is_integer(cap) and cap > 0
      assert DuplicateSweep.normalize_max_merges(0) == cap
      assert DuplicateSweep.normalize_max_merges(-1) == cap
      assert DuplicateSweep.normalize_max_merges("50") == cap
      assert DuplicateSweep.normalize_max_merges(50) == 50

      refute DuplicateSweep.merge_cap_reached?(nil, 0)
      refute DuplicateSweep.merge_cap_reached?(nil, 10_000)
      refute DuplicateSweep.merge_cap_reached?(cap, cap - 1)
      assert DuplicateSweep.merge_cap_reached?(cap, cap)
      assert DuplicateSweep.merge_cap_reached?(50, 50)
    end
  end

  test "does not use hardware serial ambiguity for unattended merges" do
    types = DuplicateSweep.automatic_merge_identifier_types()

    refute :hardware_serial in types
    assert :agent_id in types
    assert :armis_device_id in types
    assert :integration_id in types
    assert :mac in types
  end
end
