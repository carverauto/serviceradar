defmodule ServiceRadar.Inventory.Sync.SourcePolicyMdnsTest do
  @moduledoc """
  netprobe mDNS may describe a device. It may never create one.

  An mDNS announcement is a claim a host broadcasts about itself on a group
  anyone can join. It is good evidence about what something IS and no evidence
  that it is present at all -- so a device that exists only because something
  announced it has a name, a model and a type with no sighting behind any of
  them. The census establishes presence from ARP/NDP; mDNS enriches what the
  census already found.
  """
  use ExUnit.Case, async: true

  alias ServiceRadar.Inventory.Sync.SourcePolicy

  defp update(source, metadata), do: %{source: source, metadata: metadata}

  describe "enrichment-only source detection" do
    test "recognises mDNS by source name or identity_source" do
      assert SourcePolicy.enrichment_only_source?(update("netprobe-mdns", %{}))
      assert SourcePolicy.enrichment_only_source?(update("passive-mdns", %{}))
      assert SourcePolicy.enrichment_only_source?(update("Netprobe-mDNS", %{}))

      assert SourcePolicy.enrichment_only_source?(
               update("agent", %{"identity_source" => "netprobe_mdns"})
             )
    end

    test "the census is NOT enrichment-only" do
      # The load-bearing negative control. The census exists to bring newly
      # sighted devices into inventory; classing it here would silently stop
      # every first sighting from creating anything, and the symptom -- an
      # inventory that never grows -- looks like a quiet network.
      refute SourcePolicy.enrichment_only_source?(update("netprobe-census", %{}))
      refute SourcePolicy.enrichment_only_source?(update("passive-census", %{}))
    end

    test "does not claim unrelated sources" do
      refute SourcePolicy.enrichment_only_source?(update("armis", %{}))
      refute SourcePolicy.enrichment_only_source?(update("sweep", %{}))
      refute SourcePolicy.enrichment_only_source?(update("mapper", %{}))
      refute SourcePolicy.enrichment_only_source?(nil)
    end

    test "passive netprobe fingerprints are enrichment-only too" do
      # This line used to be a `refute`. It was wrong, and the cost was a
      # REPRODUCED over-merge: passive-netprobe was absent from every branch of
      # observer_agent_source?/1, so the COLLECTOR's agent_id -- which the agent
      # stamps on every fingerprint update -- stayed first in the identifier
      # priority and every fingerprinted host strong-matched the collector's own
      # device. See sync_ingestor_passive_netprobe_identity_test.exs.
      assert SourcePolicy.enrichment_only_source?(update("passive-netprobe", %{}))
      assert SourcePolicy.observer_agent_source?(update("passive-netprobe", %{}))

      assert SourcePolicy.enrichment_only_source?(
               update("agent", %{"identity_source" => "netprobe_fingerprint"})
             )

      assert SourcePolicy.enrichment_only_source?(
               update("agent", %{"identity_source" => "netprobe_dpi"})
             )
    end
  end

  describe "the collector is an observer, not the device" do
    test "an mDNS update's agent_id must not become a device identifier" do
      # The collector overhears announcements from every host on the segment.
      # If its agent_id registered as an identifier, every device mDNS ever
      # described would carry the SAME identifier and collapse onto one
      # another -- the over-merge failure the census is excluded here to avoid.
      assert SourcePolicy.observer_agent_source?(update("netprobe-mdns", %{}))

      assert SourcePolicy.observer_agent_source?(
               update("agent", %{"identity_source" => "netprobe_mdns"})
             )
    end
  end

  describe "the MAC is still usable for lookup" do
    test "mDNS may look a device up by MAC" do
      # Enrichment-only restricts CREATION, not matching. Refusing the MAC here
      # would leave an mDNS update with no identifier at all -- it carries no
      # IP and its agent_id is the observer's -- so every announcement would be
      # discarded and the feature would be inert rather than safe.
      assert SourcePolicy.include_mac_identifier?(
               update("netprobe-mdns", %{"mac" => "aa:bb:cc:dd:ee:01"})
             )
    end
  end

  describe "router and policy must agree on what mDNS is called" do
    test "every mDNS service type the router accepts is one SourcePolicy recognises" do
      # If these drift, the router hands mDNS payloads to the SyncIngestor
      # while the enrichment gate does not recognise them -- so announcements
      # mint devices, with no error anywhere to say so.
      for service_type <- ServiceRadar.ResultsRouter.mdns_service_types() do
        source = service_type |> to_string() |> String.replace("_", "-")

        assert SourcePolicy.enrichment_only_source?(update(source, %{})),
               "router accepts service_type #{inspect(service_type)} but SourcePolicy " <>
                 "does not recognise #{inspect(source)} as enrichment-only"
      end
    end

    test "the Go agent's source string is one of them" do
      # models.DiscoverySourceNetprobeMdns in go/pkg/models/discovery.go. A
      # drift there is a cross-language break with no compiler on either side.
      assert "netprobe-mdns" in Enum.map(
               ServiceRadar.ResultsRouter.mdns_service_types(),
               &to_string/1
             )

      assert SourcePolicy.enrichment_only_source?(update("netprobe-mdns", %{}))
    end

    test "the mDNS and census routes stay distinct" do
      # Two streams with opposite creation rules. One list swallowing the other
      # would apply the wrong rule to a whole stream.
      census = MapSet.new(ServiceRadar.ResultsRouter.census_service_types(), &to_string/1)
      mdns = MapSet.new(ServiceRadar.ResultsRouter.mdns_service_types(), &to_string/1)

      assert MapSet.disjoint?(census, mdns)
    end
  end
end
