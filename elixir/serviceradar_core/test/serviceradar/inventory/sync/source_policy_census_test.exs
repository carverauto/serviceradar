defmodule ServiceRadar.Inventory.Sync.SourcePolicyCensusTest do
  @moduledoc """
  The passive census must never let a randomized MAC anchor a canonical device.

  iOS and Android rotate their MAC per SSID, and the census observes every device
  that touches the segment -- so without this, a rotating phone mints a fresh
  device on every rotation, which is the anchorless-device and IP-squatting
  failure mode at far higher volume than a sweep produces.
  """
  use ExUnit.Case, async: true

  alias ServiceRadar.Inventory.Sync.SourcePolicy

  defp update(source, metadata), do: %{source: source, metadata: metadata}

  describe "passive census source detection" do
    test "recognises the census by source name or identity_source" do
      assert SourcePolicy.passive_census_source?(update("passive-census", %{}))
      assert SourcePolicy.passive_census_source?(update("netprobe-census", %{}))

      assert SourcePolicy.passive_census_source?(
               update("agent", %{"identity_source" => "passive_census"})
             )

      assert SourcePolicy.passive_census_source?(update("Passive-Census", %{}))
    end

    test "does not claim unrelated sources" do
      refute SourcePolicy.passive_census_source?(update("armis", %{}))
      refute SourcePolicy.passive_census_source?(update("sweep", %{}))
      refute SourcePolicy.passive_census_source?(update("netbox", %{}))
      refute SourcePolicy.passive_census_source?(nil)
    end
  end

  describe "randomized MACs from the census" do
    test "a locally administered MAC is not registered as an identity anchor" do
      # Bit 1 of the first octet set: 0x1A, 0x02, 0x06, 0x0A, 0x0E ...
      for mac <- ["1A:2B:3C:4D:5E:6F", "02:00:00:00:00:01", "DA:AA:BB:CC:DD:EE"] do
        refute SourcePolicy.include_mac_identifier?(update("passive-census", %{"mac" => mac})),
               "#{mac} is locally administered and must not anchor a device"
      end
    end

    test "a burned-in vendor MAC from the census still anchors" do
      for mac <- ["BC:24:11:F5:1C:82", "F4:92:BF:75:C7:2B", "D0:21:F9:DC:2E:8C"] do
        assert SourcePolicy.include_mac_identifier?(update("passive-census", %{"mac" => mac})),
               "#{mac} is universally administered and keeps its identity weight"
      end
    end

    test "a census observation with no MAC anchors nothing" do
      refute SourcePolicy.include_mac_identifier?(update("passive-census", %{}))
      refute SourcePolicy.include_mac_identifier?(update("passive-census", %{"mac" => nil}))
    end

    test "identity_mac is accepted as the field name too" do
      refute SourcePolicy.include_mac_identifier?(
               update("passive-census", %{"identity_mac" => "1A:2B:3C:4D:5E:6F"})
             )

      assert SourcePolicy.include_mac_identifier?(
               update("passive-census", %{"identity_mac" => "BC:24:11:F5:1C:82"})
             )
    end
  end

  describe "the guardrail is scoped to the census" do
    test "virtualization sources keep locally administered MACs" do
      # Identity.Mac documents that locally administered MACs are also how
      # virtualization, Docker and overlay networks address themselves. Scoping
      # the rule to the census is what keeps those devices working; a global
      # rule would stop them re-deriving their UID.
      assert SourcePolicy.include_mac_identifier?(
               update("armis", %{"mac" => "02:42:AC:11:00:02"})
             ),
             "a Docker-style MAC from a non-census source must keep its current meaning"

      assert SourcePolicy.include_mac_identifier?(update("sync", %{"mac" => "1A:2B:3C:4D:5E:6F"}))
    end

    test "mapper-like sources keep their own unchanged rule" do
      refute SourcePolicy.include_mac_identifier?(
               update("mapper", %{"identity_mac_kind" => "interface"})
             )

      assert SourcePolicy.include_mac_identifier?(
               update("mapper", %{"identity_mac_kind" => "primary"})
             )
    end
  end

  describe "the collector's agent_id must not identify the devices it overhears" do
    test "census agent_id is treated as an observer, like mapper and sweep" do
      # The collector never touches the devices it reports -- it overhears their
      # ARP/NDP. If its agent_id registered as a device identifier, EVERY device
      # on the segment would carry the same identifier and collapse onto one
      # another. This is the over-merge failure mapper/sweep are excluded to
      # avoid, and the census is the strongest case of it.
      ids = %{agent_id: "collector-agent-1"}

      for source <- ["netprobe-census", "passive-census"] do
        assert SourcePolicy.observer_agent_source?(update(source, %{})),
               "#{source} must be treated as an observer source"

        refute SourcePolicy.include_agent_identifier?(update(source, %{}), ids),
               "#{source} must not register the collector agent_id as a device identifier"
      end
    end

    test "identifier_types drops agent_id for a census update but keeps it for a plain agent" do
      ids = %{agent_id: "collector-agent-1"}

      refute :agent_id in SourcePolicy.identifier_types(update("netprobe-census", %{}), ids)

      # Negative control: an ordinary agent-reported update still identifies by
      # agent_id, so the exclusion above is specific rather than a blanket rule.
      assert :agent_id in SourcePolicy.identifier_types(update("self-reported", %{}), ids)
    end

    test "the identity_source form is recognised too" do
      ids = %{agent_id: "collector-agent-1"}
      census = update("agent", %{"identity_source" => "netprobe_census"})

      assert SourcePolicy.observer_agent_source?(census)
      refute SourcePolicy.include_agent_identifier?(census, ids)
    end
  end

  describe "the metadata contract the Go translator has to satisfy" do
    test "anchoring reads metadata[\"mac\"], not a top-level mac field" do
      # Normalize.merge_top_level_inventory_metadata/2 does NOT copy the
      # top-level `mac` into metadata, so the census producer must place it
      # there itself (census_translator.go sets censusMetadataMAC = "mac").
      # Pinning it here means a producer change that drops it fails a test
      # instead of silently disabling MAC anchoring for every census device.
      universal = "BC:24:11:F5:1C:82"

      assert SourcePolicy.include_mac_identifier?(
               update("netprobe-census", %{"mac" => universal})
             )

      refute SourcePolicy.include_mac_identifier?(
               Map.put(update("netprobe-census", %{}), :mac, universal)
             ),
             "a top-level mac with no metadata[\"mac\"] must fail closed"
    end
  end

  describe "router and policy must agree on what the census is called" do
    test "every census service type the router accepts is one SourcePolicy recognises" do
      # THE guardrail pairing. The router decides whether a census payload
      # reaches the SyncIngestor at all; SourcePolicy decides whether its MAC
      # may anchor a device. If these two lists drift, the stream ingests
      # normally with the guardrail silently inert -- no error anywhere, just
      # randomized MACs minting a device per rotation.
      #
      # This lives in the unit tier on purpose: results_router_test.exs uses
      # ServiceRadar.DataCase (@moduletag :requires_app), which the unit tier
      # excludes, so the routing assertions there run only in the integration
      # shards. This invariant needs no app.
      for service_type <- ServiceRadar.ResultsRouter.census_service_types() do
        source = service_type |> to_string() |> String.replace("_", "-")

        assert SourcePolicy.passive_census_source?(update(source, %{})),
               "router accepts service_type #{inspect(service_type)} but SourcePolicy " <>
                 "does not recognise #{inspect(source)} as a census source"
      end
    end

    test "the Go agent's source string is one of them" do
      # models.DiscoverySourceNetprobeCensus in go/pkg/models/discovery.go. A
      # drift there is a cross-language break with no compiler on either side.
      assert "netprobe-census" in Enum.map(
               ServiceRadar.ResultsRouter.census_service_types(),
               &to_string/1
             )

      assert SourcePolicy.passive_census_source?(update("netprobe-census", %{}))
    end
  end

  describe "addressless census observations may not create a device" do
    # RFC 5227 ARP probes are a designed, golden-pinned observation: a host
    # asking whether an address is free sends ARP with a zero sender address.
    # The decoder keeps them. What was never decided -- until GitHub #4050 --
    # is that they should become a permanent ocsf_devices row. They describe
    # an address being claimed, not one that is held.
    defp census(ip) do
      %{source: "netprobe-census", ip: ip, metadata: %{"identity_source" => "netprobe_census"}}
    end

    test "a census sighting with an address may still create" do
      assert SourcePolicy.sufficient_to_create?(census("192.0.2.10"))
    end

    test "an ARP probe with no address may not create" do
      refute SourcePolicy.sufficient_to_create?(census(""))
      refute SourcePolicy.sufficient_to_create?(census(nil))
      refute SourcePolicy.sufficient_to_create?(update("netprobe-census", %{}))
    end

    test "mDNS remains unable to create, as before" do
      refute SourcePolicy.sufficient_to_create?(update("netprobe-mdns", %{}))
    end

    test "an AWX host addressed only by DNS name may still create" do
      # Per-source, not global. A DNS-only ansible host is real inventory with
      # no IP to record; refusing it drops the row. The ARP probe is the
      # opposite judgement.
      awx = %{source: "awx", ip: nil, metadata: %{"integration_id" => "awx:v2:ctrl:host:1"}}

      assert SourcePolicy.sufficient_to_create?(awx)
    end
  end
end
