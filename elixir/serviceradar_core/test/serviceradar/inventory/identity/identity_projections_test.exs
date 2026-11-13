defmodule ServiceRadar.Inventory.Identity.IdentityProjectionsTest do
  @moduledoc """
  The projection table an unmerge applies to each record of the pair (`MergeEngine.unmerge_device/2`
  writes it through `IdentityProjections.drop/2`). Invented values: one AWX controller, one Proxmox
  cluster, MACs under the IANA documentation OUI 00-00-5E.
  """

  use ExUnit.Case, async: true

  alias ServiceRadar.Inventory.Identity.IdentityProjections

  @controller "00000000-0000-4000-8000-0000000000c1"
  @guest "proxmox:v2:cluster-x:vm:9217"
  @guest_mac "00005E005317"
  @own_mac "00005E005313"

  # What enrichment and sync wrote onto a survivor while it held guest 9217's rows, beside what is
  # its own.
  @survivor_metadata %{
    "integration_id" => @guest,
    "integration_type" => "hypervisor",
    "hypervisor_provider" => "proxmox",
    "hypervisor_provider_ref" => @guest,
    "hypervisor_vmid" => 9217,
    "hypervisor_status" => "running",
    "mac_addresses" => ["00:00:5e:00:53:17", @own_mac],
    "awx" => %{"controller_id" => @controller, "host_id" => 71},
    "device_role" => "virtual-guest"
  }

  test "removes exactly the projections that name the other record's identifiers" do
    # As the merge audit recorded the merged record's identifiers.
    foreign =
      IdentityProjections.foreign([
        %{"type" => "integration_id", "value" => @guest, "partition" => "default"},
        %{"type" => "integration_id", "value" => "awx:v2:#{@controller}:host:71"},
        %{"type" => "mac", "value" => @guest_mac},
        %{"type" => "ip", "value" => "192.0.2.17"}
      ])

    plan = IdentityProjections.plan("00:00:5E:00:53:17", @survivor_metadata, foreign)

    assert plan.mac == {:set, nil}
    assert plan.put == %{"mac_addresses" => [@own_mac]}

    assert Enum.sort(plan.delete) ==
             Enum.sort(~w(
               integration_id integration_type hypervisor_provider hypervisor_provider_ref
               hypervisor_vmid hypervisor_status awx
             ))

    assert plan.dropped == %{
             "mac" => "00:00:5E:00:53:17",
             "mac_addresses" => ["00:00:5e:00:53:17"],
             "metadata" => Map.drop(@survivor_metadata, ["mac_addresses", "device_role"])
           }
  end

  test "keeps every projection that names nothing foreign" do
    foreign =
      IdentityProjections.foreign([
        %{type: :mac, value: "00005E0053FF"},
        %{type: :ip, value: "x"}
      ])

    for {mac, metadata} <- [
          {"00:00:5E:00:53:13", @survivor_metadata},
          {nil, %{}},
          {"not-a-mac", nil}
        ] do
      assert %{mac: :keep, delete: [], put: put, dropped: dropped} =
               IdentityProjections.plan(mac, metadata, foreign)

      assert put == %{} and dropped == %{}
    end
  end

  test "an AWX metadata map names its host only with both its controller and its host" do
    assert IdentityProjections.claimed_awx_id(%{"controller_id" => @controller, "host_id" => 71}) ==
             "awx:v2:#{@controller}:host:71"

    assert IdentityProjections.claimed_awx_id(%{"controller_id" => @controller}) == nil
    assert IdentityProjections.claimed_awx_id(%{"host_id" => " ", "controller_id" => "c"}) == nil
    assert IdentityProjections.claimed_awx_id(nil) == nil
  end
end
