defmodule ServiceRadar.Inventory.Sync.SourcePolicyCreateEligibilityTest do
  @moduledoc """
  Per-source answers to "may this update mint a device?"

  Proxmox, NetBox, and hypervisor enrichment already skip address-less
  records at the producer. This is the Elixir-side copy of that rule so a
  slipped payload cannot mint an ocsf_devices row the producer refused.
  """
  use ExUnit.Case, async: true

  alias ServiceRadar.Inventory.Sync.SourcePolicy

  defp update(source, ip, metadata \\ %{}) do
    %{source: source, ip: ip, metadata: metadata}
  end

  describe "sources whose producer already refuses an empty IP" do
    test "cannot create without an address, and still can with one" do
      for source <- ["proxmox", "netbox", "hypervisor_enrichment"] do
        refute SourcePolicy.sufficient_to_create?(update(source, nil)),
               "#{source} must not mint a device with ip=nil"

        refute SourcePolicy.sufficient_to_create?(update(source, "")),
               "#{source} must not mint a device with a blank ip"

        assert SourcePolicy.sufficient_to_create?(update(source, "192.0.2.10")),
               "#{source} with a real address must still be able to create"
      end
    end

    test "source match is case-insensitive" do
      refute SourcePolicy.sufficient_to_create?(update("Proxmox", nil))
      refute SourcePolicy.sufficient_to_create?(update("NETBOX", ""))
    end
  end
end
