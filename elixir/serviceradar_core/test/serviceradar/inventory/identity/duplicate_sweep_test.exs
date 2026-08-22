defmodule ServiceRadar.Inventory.Identity.DuplicateSweepTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Inventory.Identity.DuplicateSweep

  describe "column_mac_groups_from_rows/1" do
    test "pairs a device carrying a MAC only on its row with the device that registered it" do
      # device_identifiers is UNIQUE on (identifier_type, identifier_value,
      # partition), so a second device can never register the same MAC. Without
      # this grouping the two records stay split forever: duplicate-identifier
      # grouping cannot see them, and neither can the sibling grouping, which
      # needs both sides registered.
      rows = [{"AC8BA9D587DD", "sr:column-side", "sr:identifier-owner", "default"}]

      assert [{{"default", :mac_column, "AC8BA9D587DD"}, members}] =
               DuplicateSweep.column_mac_groups_from_rows(rows)

      assert MapSet.equal?(members, MapSet.new(["sr:column-side", "sr:identifier-owner"]))
    end

    test "never merges on a locally-administered MAC" do
      # Randomized phone Wi-Fi and virtual bridges are not globally unique;
      # merging on them would collapse unrelated hardware.
      rows = [
        {"1E14049215A9", "sr:a", "sr:b", "default"},
        {"56FE96003BA7", "sr:c", "sr:d", "default"},
        {"A67C5557004F", "sr:e", "sr:f", "default"}
      ]

      assert DuplicateSweep.column_mac_groups_from_rows(rows) == []
    end

    test "keeps globally-unique MACs and drops locally-administered ones in the same batch" do
      rows = [
        {"1CB3C9126C6C", "sr:keep-a", "sr:keep-b", "default"},
        {"C2AB756587EF", "sr:drop-a", "sr:drop-b", "default"}
      ]

      assert [{{"default", :mac_column, "1CB3C9126C6C"}, _}] =
               DuplicateSweep.column_mac_groups_from_rows(rows)
    end

    test "partitions scope the group key" do
      rows = [
        {"1CB3C9126C6C", "sr:a", "sr:b", "default"},
        {"1CB3C9126C6C", "sr:c", "sr:d", "tenant-2"}
      ]

      keys = rows |> DuplicateSweep.column_mac_groups_from_rows() |> Enum.map(&elem(&1, 0))

      assert {"default", :mac_column, "1CB3C9126C6C"} in keys
      assert {"tenant-2", :mac_column, "1CB3C9126C6C"} in keys
    end

    test "is empty for no rows" do
      assert DuplicateSweep.column_mac_groups_from_rows([]) == []
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
