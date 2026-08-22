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
end
