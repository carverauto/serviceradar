defmodule ServiceRadar.Inventory.Sync.LookupsEnrichmentTest do
  @moduledoc """
  The decision the enrichment-only gate rests on: does this update already name
  a device?

  SyncIngestor drops enrichment-only updates that answer "no" rather than let
  BatchResolver mint a uid for them. That drop is silent by design -- an mDNS
  announcement from a host inventory has never seen is not an error -- so the
  predicate itself is where the behaviour has to be pinned down.
  """
  use ExUnit.Case, async: true

  alias ServiceRadar.Inventory.Sync.Lookups

  @partition "default"

  defp mdns_update(mac) do
    %{
      source: "netprobe-mdns",
      mac: mac,
      ip: nil,
      partition: @partition,
      metadata: %{
        "mac" => mac,
        "identity_source" => "netprobe_mdns",
        "agent_id" => "collector-1",
        "mdns.service_types" => "_airplay._tcp"
      }
    }
  end

  # Identifier values are stored normalized: colonless and upper case. Building
  # the fixture from the raw form would silently never match, and the test
  # would then assert the gate rejects everything.
  defp mapping_for(mac, partition \\ @partition, device_id \\ "sr:device:known") do
    normalized = mac |> String.replace(":", "") |> String.upcase()

    %{{:mac, normalized, partition} => device_id}
  end

  describe "matches_existing_device?/2" do
    test "an announcement from a device inventory already knows matches" do
      update = mdns_update("AA:BB:CC:DD:EE:01")

      assert Lookups.matches_existing_device?(update, mapping_for("AA:BB:CC:DD:EE:01"))
    end

    test "an announcement from a device nothing has ever sighted does not" do
      # This is the case the gate exists for. Answering "yes" here would let a
      # single multicast packet create a device with a model and a type and no
      # sighting behind either.
      update = mdns_update("AA:BB:CC:DD:EE:02")

      refute Lookups.matches_existing_device?(update, mapping_for("AA:BB:CC:DD:EE:01"))
    end

    test "an empty mapping matches nothing" do
      refute Lookups.matches_existing_device?(mdns_update("AA:BB:CC:DD:EE:01"), %{})
    end

    test "the same MAC in another partition is a different device" do
      update = mdns_update("AA:BB:CC:DD:EE:01")

      refute Lookups.matches_existing_device?(
               update,
               mapping_for("AA:BB:CC:DD:EE:01", "other-partition")
             )
    end

    test "the U/L-bit sibling of a known MAC matches, as it does everywhere else" do
      # Ids.mac_lookup_values expands a MAC to its locally-administered sibling
      # so that a device seen once with the bit set and once without resolves to
      # one device. Enrichment deliberately inherits that rule rather than
      # inventing a stricter one: a gate that matched differently from the
      # resolver would enrich a device the resolver would not have picked.
      update = mdns_update("AA:BB:CC:DD:EE:01")

      assert Lookups.matches_existing_device?(update, mapping_for("A8:BB:CC:DD:EE:01"))
    end

    test "the collector's own agent_id cannot satisfy the match" do
      # mDNS is an observer source, so effective_identifiers/1 strips agent_id.
      # If it did not, every announcement would "match" the collector's own
      # device row and enrich it with whatever the segment was advertising.
      update = mdns_update("AA:BB:CC:DD:EE:02")
      mapping = %{{:agent_id, "collector-1", @partition} => "sr:device:collector"}

      refute Lookups.matches_existing_device?(update, mapping)
    end
  end

  describe "the gate and the lookup consult the same identifiers" do
    test "update_identifiers/1 is exactly what extract_all_identifiers/1 queries for" do
      # The invariant that makes the gate safe. If the gate asked about an
      # identifier the bulk lookup never searched for, the answer would always
      # be "no match" and every enrichment update would be dropped -- an inert
      # feature with no error to say so. If the lookup searched for one the
      # gate ignores, an update that DID match would be dropped anyway.
      update = mdns_update("AA:BB:CC:DD:EE:01")

      assert MapSet.new(Lookups.update_identifiers(update)) ==
               MapSet.new(Lookups.extract_all_identifiers([update]))
    end

    test "the MAC is among them, so an mDNS update can be matched at all" do
      update = mdns_update("AA:BB:CC:DD:EE:01")
      types = update |> Lookups.update_identifiers() |> Enum.map(&elem(&1, 0))

      assert :mac in types
    end
  end
end
