defmodule ServiceRadarWebNGWeb.Helpers.VirtualizationLabelsTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.Helpers.VirtualizationLabels

  @moduletag :db_free

  describe "provider_label/1" do
    test "formats known provider names" do
      assert VirtualizationLabels.provider_label("proxmox") == "Proxmox"
      assert VirtualizationLabels.provider_label("vsphere") == "vSphere"
      assert VirtualizationLabels.provider_label("vcenter") == "vCenter"
      assert VirtualizationLabels.provider_label("vmware") == "VMware"
    end

    test "formats unknown provider ids for display" do
      assert VirtualizationLabels.provider_label("nutanix_ahv") == "Nutanix Ahv"
      assert VirtualizationLabels.provider_label("hyper-v") == "Hyper V"
    end

    test "handles maps and blank values" do
      assert VirtualizationLabels.provider_label(%{provider: "vsphere"}) == "vSphere"
      assert VirtualizationLabels.provider_label("") == "Hypervisor"
      assert VirtualizationLabels.provider_label(nil) == "Hypervisor"
    end
  end

  describe "provider_summary/2" do
    test "summarizes mixed provider rows" do
      rows = [
        %{"provider" => "proxmox"},
        %{"provider" => "vsphere"},
        %{provider: "proxmox"}
      ]

      assert VirtualizationLabels.provider_summary(rows) == "Proxmox +1"
    end

    test "returns empty label when no provider is present" do
      assert VirtualizationLabels.provider_summary([], "Empty") == "Empty"
      assert VirtualizationLabels.provider_summary([%{}], "Empty") == "Empty"
    end
  end
end
