defmodule ServiceRadar.Edge.RemoteConsoleTargetResolverTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Edge.RemoteConsoleTargetResolver
  alias ServiceRadar.Inventory.VirtualizationGuest
  alias ServiceRadar.Inventory.VirtualizationHost

  test "resolves a Proxmox host target from virtualization inventory" do
    lookup = fn
      VirtualizationHost, "sr:host-1", _ash_opts ->
        {:ok, [%{provider: "proxmox", provider_ref: "proxmox:cluster-a:host:pve01"}]}

      VirtualizationGuest, "sr:host-1", _ash_opts ->
        flunk("guest lookup should not run after matching host inventory")
    end

    assert {:ok, target} =
             RemoteConsoleTargetResolver.resolve_proxmox(
               %{uid: "sr:host-1", vendor_name: "Proxmox"},
               %{},
               virtualization_lookup: lookup
             )

    assert target == %{
             target_kind: :pve_host,
             console_mode: :proxmox_termproxy,
             provider_ref: "proxmox:cluster-a:host:pve01"
           }
  end

  test "infers guest kind and accepts the native LXC console mode" do
    lookup = fn
      VirtualizationHost, "sr:guest-101", _ash_opts ->
        {:ok, []}

      VirtualizationGuest, "sr:guest-101", _ash_opts ->
        {:ok,
         [
           %{
             provider: "proxmox",
             provider_ref: "proxmox:cluster-a:guest:101",
             guest_type: "lxc"
           }
         ]}
    end

    assert {:ok, target} =
             RemoteConsoleTargetResolver.resolve_proxmox(
               %{uid: "sr:guest-101"},
               %{"console_mode" => "proxmox_termproxy"},
               virtualization_lookup: lookup
             )

    assert target == %{
             target_kind: :lxc_guest,
             console_mode: :proxmox_termproxy,
             provider_ref: "proxmox:cluster-a:guest:101"
           }
  end

  test "ignores non-Proxmox virtualization rows when resolving Proxmox targets" do
    lookup = fn
      VirtualizationHost, "sr:vsphere-host-1", _ash_opts ->
        {:ok, [%{provider: "vsphere", provider_ref: "vsphere:vcenter-a:host:host-1"}]}

      VirtualizationGuest, "sr:vsphere-host-1", _ash_opts ->
        {:ok, []}
    end

    assert {:error, :unsupported_console_target} =
             RemoteConsoleTargetResolver.resolve_proxmox(
               %{uid: "sr:vsphere-host-1", vendor_name: "VMware"},
               %{},
               virtualization_lookup: lookup
             )
  end

  test "falls back to device vendor when virtualization lookup is unavailable" do
    lookup = fn _resource, _device_uid, _ash_opts -> {:error, :db_unavailable} end

    assert {:ok, target} =
             RemoteConsoleTargetResolver.resolve_proxmox(
               %{uid: "sr:host-2", vendor_name: "Proxmox VE"},
               %{},
               virtualization_lookup: lookup
             )

    assert target.target_kind == :pve_host
    assert target.console_mode == :proxmox_termproxy
    assert is_nil(target.provider_ref)
  end

  test "rejects non-hypervisor devices without virtualization inventory" do
    lookup = fn _resource, _device_uid, _ash_opts -> {:ok, []} end

    assert {:error, :unsupported_console_target} =
             RemoteConsoleTargetResolver.resolve_proxmox(
               %{uid: "sr:switch-1", vendor_name: "Juniper"},
               %{},
               virtualization_lookup: lookup
             )
  end
end
