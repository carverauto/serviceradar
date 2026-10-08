defmodule ServiceRadar.Inventory.Identity.DuplicateSweepTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Inventory.Identity.DuplicateSweep

  describe "interface_mac_chassis_groups_from_rows/1" do
    test "pairs a chassis only when both devices claim the other's anchor MAC" do
      rows = [
        {"001122334455", "sr:lan-side", "sr:wan-side", "default", "default", "default",
         "default"},
        {"00AABBCCDDEE", "sr:wan-side", "sr:lan-side", "default", "default", "default", "default"}
      ]

      assert [{{"default", :interface_mac_chassis, "001122334455"}, members}] =
               DuplicateSweep.interface_mac_chassis_groups_from_rows(rows)

      assert MapSet.equal?(members, MapSet.new(["sr:lan-side", "sr:wan-side"]))
    end

    test "rejects a one-sided interface claim" do
      rows = [
        {"001122334455", "sr:reporter", "sr:target", "default", "default", "default", "default"}
      ]

      assert DuplicateSweep.interface_mac_chassis_groups_from_rows(rows) == []
    end

    test "never merges on a locally-administered interface MAC" do
      rows = [
        {"021122334455", "sr:host", "sr:guest", "default", "default", "default", "default"},
        {"06AABBCCDDEE", "sr:a", "sr:b", "default", "default", "default", "default"},
        {"0A1122334455", "sr:c", "sr:d", "default", "default", "default", "default"}
      ]

      assert DuplicateSweep.interface_mac_chassis_groups_from_rows(rows) == []
    end

    test "collapses duplicate reciprocal evidence for the same pair" do
      rows = [
        {"001122334455", "sr:lan", "sr:wan", "default", "default", "default", "default"},
        {"001122334455", "sr:lan", "sr:wan", "default", "default", "default", "default"},
        {"00AABBCCDDEE", "sr:wan", "sr:lan", "default", "default", "default", "default"}
      ]

      assert [{{"default", :interface_mac_chassis, "001122334455"}, _}] =
               DuplicateSweep.interface_mac_chassis_groups_from_rows(rows)
    end

    test "keeps reciprocal universal claims and drops locally-administered claims" do
      rows = [
        {"001122334455", "sr:keep-a", "sr:keep-b", "default", "default", "default", "default"},
        {"00AABBCCDDEE", "sr:keep-b", "sr:keep-a", "default", "default", "default", "default"},
        {"021122334455", "sr:drop-a", "sr:drop-b", "default", "default", "default", "default"},
        {"0A1122334455", "sr:drop-b", "sr:drop-a", "default", "default", "default", "default"}
      ]

      assert [{{"default", :interface_mac_chassis, "001122334455"}, members}] =
               DuplicateSweep.interface_mac_chassis_groups_from_rows(rows)

      assert MapSet.equal?(members, MapSet.new(["sr:keep-a", "sr:keep-b"]))
    end

    test "rejects a mismatch at every partition boundary" do
      forward =
        {"001122334455", "sr:a", "sr:b", "default", "default", "default", "default"}

      reciprocal =
        {"00AABBCCDDEE", "sr:b", "sr:a", "default", "default", "default", "default"}

      for tuple_index <- 3..6 do
        mismatched = put_elem(reciprocal, tuple_index, "edge")

        assert DuplicateSweep.interface_mac_chassis_groups_from_rows([forward, mismatched]) == []
      end
    end

    test "returns the same reciprocal evidence regardless of row order" do
      rows = [
        {"001122334455", "sr:a", "sr:b", "default", "default", "default", "default"},
        {"00AABBCCDDEE", "sr:b", "sr:a", "default", "default", "default", "default"}
      ]

      assert DuplicateSweep.interface_mac_chassis_groups_from_rows(rows) ==
               DuplicateSweep.interface_mac_chassis_groups_from_rows(Enum.reverse(rows))
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

  describe "hardware_mac_sibling_groups_from_rows/2" do
    test "keys a pair by its universal member, whichever row the scan returns first" do
      # The scan has no order. A key that followed it would change the component's evidence,
      # and so its block fingerprint, between two runs over the same rows.
      rows = [
        {"02005E005301", "sr:local-side", "default"},
        {"00005E005301", "sr:universal-side", "default"}
      ]

      for ordered <- [rows, Enum.reverse(rows)] do
        assert [{{"default", :mac_sibling, "00005E005301"}, members}] =
                 DuplicateSweep.hardware_mac_sibling_groups_from_rows("default", ordered)

        assert MapSet.equal?(members, MapSet.new(["sr:local-side", "sr:universal-side"]))
      end
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

    test "blocks a pair whose only evidence is a randomized :mac" do
      entries = [
        {{"default", :mac, "A2B2C3D4E5F6"}, MapSet.new(["sr:a", "sr:b"])}
      ]

      assert %{mergeable: [], blocked: [blocked]} =
               DuplicateSweep.classify_duplicate_components(entries)

      assert blocked.device_ids == ["sr:a", "sr:b"]
    end

    test "allows a pair whose evidence is a globally-unique :mac" do
      entries = [
        {{"default", :mac, "A1B2C3D4E5F6"}, MapSet.new(["sr:a", "sr:b"])}
      ]

      assert %{mergeable: [merged], blocked: []} =
               DuplicateSweep.classify_duplicate_components(entries)

      assert merged.device_ids == ["sr:a", "sr:b"]
    end

    test "allows a pair with mixed :mac and :agent_id evidence" do
      entries = [
        {{"default", :mac, "A1B2C3D4E5F6"}, MapSet.new(["sr:a", "sr:b"])},
        {{"default", :agent_id, "agent-x"}, MapSet.new(["sr:a", "sr:b"])}
      ]

      assert %{mergeable: [merged], blocked: []} =
               DuplicateSweep.classify_duplicate_components(entries)

      assert merged.device_ids == ["sr:a", "sr:b"]
    end

    test "allows a pair with :interface_mac_chassis evidence (hardware, not blocked by MAC-only rule)" do
      entries = [
        {{"default", :interface_mac_chassis, "A1B2C3D4E5F6"}, MapSet.new(["sr:a", "sr:b"])}
      ]

      assert %{mergeable: [merged], blocked: []} =
               DuplicateSweep.classify_duplicate_components(entries)

      assert merged.device_ids == ["sr:a", "sr:b"]
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

  describe "report_blocked_components/1" do
    test "returns the largest blocked component size instead of :ok" do
      # The size was computed for a log line and then discarded, so nothing
      # downstream could record it. Returning it is the whole point.
      components = [
        %{device_ids: ["sr:a", "sr:b", "sr:c"], evidence: []},
        %{device_ids: ["sr:d", "sr:e", "sr:f", "sr:g"], evidence: []}
      ]

      assert DuplicateSweep.report_blocked_components(components) == 4
    end

    test "is zero when nothing was blocked" do
      assert DuplicateSweep.report_blocked_components([]) == 0
    end
  end

  describe "blocked_component_membership/2" do
    test "captures the device uids of each blocked component" do
      components = [
        %{device_ids: ["sr:a", "sr:b", "sr:c"], evidence: []},
        %{device_ids: ["sr:d", "sr:e"], evidence: []}
      ]

      assert DuplicateSweep.blocked_component_membership(components, 10) == [
               %{"device_ids" => ["sr:a", "sr:b", "sr:c"]},
               %{"device_ids" => ["sr:d", "sr:e"]}
             ]
    end

    test "caps capture and says so rather than silently eliding components" do
      components =
        for n <- 1..5 do
          %{device_ids: ["sr:#{n}a", "sr:#{n}b"], evidence: []}
        end

      captured = DuplicateSweep.blocked_component_membership(components, 2)

      assert length(captured) == 3

      assert Enum.take(captured, 2) == [
               %{"device_ids" => ["sr:1a", "sr:1b"]},
               %{"device_ids" => ["sr:2a", "sr:2b"]}
             ]

      assert List.last(captured) == %{"truncated" => true, "omitted_components" => 3}
    end

    test "is an empty list when nothing was blocked" do
      assert DuplicateSweep.blocked_component_membership([], 10) == []
    end
  end

  describe "normalize_trigger/1" do
    test "accepts the two declared triggers and defaults everything else" do
      assert DuplicateSweep.normalize_trigger(:manual) == :manual
      assert DuplicateSweep.normalize_trigger("manual") == :manual
      assert DuplicateSweep.normalize_trigger(:scheduled) == :scheduled
      assert DuplicateSweep.normalize_trigger(nil) == :scheduled
      assert DuplicateSweep.normalize_trigger("nonsense") == :scheduled
      assert DuplicateSweep.normalize_trigger(42) == :scheduled
    end
  end

  describe "build_run_stats/2" do
    test "records the configured cap and whether the run reached it" do
      # Neither fact is derivable after the run from anything else that is
      # persisted: the cap is normalised once and then only read inside the
      # merge reduce.
      acc = %{
        DuplicateSweep.initial_accumulator()
        | duplicate_identifier_count: 12,
          duplicate_components: 4,
          mergeable_components: 3,
          blocked_components: 1,
          blocked_devices: 5,
          largest_blocked_component: 5,
          merges: 50,
          errors: 2,
          blocked_merges: 3,
          blocked_unchanged: 4,
          succession_merges: 6,
          successions_skipped: 7,
          successions_deferred: 8,
          succession_reviews: 9,
          max_successions_configured: 10
      }

      stats = DuplicateSweep.build_run_stats(acc, %{max_merges: 50, started_monotonic: 0})

      assert stats.max_merges_configured == 50
      assert stats.merge_cap_reached
      assert stats.merges == 50
      assert stats.errors == 2
      assert stats.largest_blocked_component == 5
      assert is_integer(stats.duration_ms)

      # Each counter carries its own value: a blocked merge is not an error, and the succession
      # pass's counts are not the duplicate pass's.
      assert stats.blocked_merges == 3
      assert stats.blocked_unchanged == 4
      assert stats.succession_merges == 6
      assert stats.successions_skipped == 7
      assert stats.successions_deferred == 8
      assert stats.succession_reviews == 9
      assert stats.max_successions_configured == 10
    end

    test "a run below its cap is not reported as capped" do
      acc = %{DuplicateSweep.initial_accumulator() | merges: 49}

      stats = DuplicateSweep.build_run_stats(acc, %{max_merges: 50, started_monotonic: 0})

      refute stats.merge_cap_reached
    end

    test "keeps every counter the previous stats map carried" do
      # Callers and log scrapers already read these keys; adding fields must not
      # remove any.
      stats =
        DuplicateSweep.build_run_stats(
          DuplicateSweep.initial_accumulator(),
          %{max_merges: 200, started_monotonic: 0}
        )

      for key <- [
            :duplicate_identifier_count,
            :duplicate_components,
            :mergeable_components,
            :blocked_components,
            :blocked_devices,
            :merges,
            :errors,
            :blocked_merges,
            :blocked_unchanged,
            :succession_merges,
            :successions_skipped,
            :successions_deferred,
            :succession_reviews,
            :max_successions_configured,
            :duration_ms
          ] do
        assert Map.has_key?(stats, key), "stats map lost #{key}"
      end
    end

    test "does not carry blocked component membership into the logged stats" do
      # The membership list goes to the run record, not into a log line.
      stats =
        DuplicateSweep.build_run_stats(
          DuplicateSweep.initial_accumulator(),
          %{max_merges: 200, started_monotonic: 0}
        )

      refute Map.has_key?(stats, :blocked_component_devices)
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
