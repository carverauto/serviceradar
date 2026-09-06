defmodule ServiceRadar.Edge.RemoteConsoleTargetResolverTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Edge.RemoteConsoleTargetResolver
  alias ServiceRadar.Inventory.IntegrationIdentity
  alias ServiceRadar.Inventory.VirtualizationGuest
  alias ServiceRadar.Inventory.VirtualizationHost

  @integration_id "018f3f56-1111-7666-8777-123456789abc"
  @farm_controller_id "018f3f56-2222-7666-8777-123456789abc"
  @tonka_controller_id "018f3f56-3333-7666-8777-123456789abc"

  test "resolves one authoritative v3 PVE host and exact controller origin" do
    host = host_row("host-farm", "sr:host-1", @farm_controller_id, "farm01", "pve01")

    lookup = fn
      VirtualizationHost, "sr:host-1", _ash_opts -> {:ok, [host]}
      VirtualizationGuest, "sr:host-1", _ash_opts -> flunk("guest lookup must not run")
    end

    assert {:ok, target} =
             RemoteConsoleTargetResolver.resolve_proxmox(
               controller_device("sr:host-1", "192.0.2.10", host),
               %{},
               virtualization_lookup: lookup
             )

    assert target.target_kind == :pve_host
    assert target.console_mode == :proxmox_termproxy
    assert target.provider_ref == host.provider_ref
    assert target.integration_id == @integration_id
    assert target.controller_id == @farm_controller_id
    assert target.cluster == "farm01"
    assert target.controller.device_uid == "sr:host-1"
    assert target.controller.base_url == "https://192.0.2.10:8006"
  end

  test "guest follows the exact current v3 owner and never uses the guest address" do
    host = host_row("host-farm", "sr:pve-farm-01", @farm_controller_id, "farm01", "pve01")
    guest = guest_row("guest-101", "sr:guest-101", host, "lxc", 101)

    lookup = fn
      VirtualizationHost, "sr:guest-101", _ash_opts -> {:ok, []}
      VirtualizationGuest, "sr:guest-101", _ash_opts -> {:ok, [guest]}
    end

    assert {:ok, target} =
             RemoteConsoleTargetResolver.resolve_proxmox(
               guest_device("sr:guest-101", "198.51.100.101", guest),
               %{},
               virtualization_lookup: lookup,
               host_lookup: fn "host-farm", _ -> {:ok, host} end,
               device_lookup: fn "sr:pve-farm-01", _ ->
                 {:ok, controller_device("sr:pve-farm-01", "192.0.2.10", host)}
               end
             )

    assert target.target_kind == :lxc_guest
    assert target.vmid == 101
    assert target.owner_host_id == "host-farm"
    assert target.controller.ip == "192.0.2.10"
    assert target.controller.base_url == "https://192.0.2.10:8006"
    refute target.controller.ip == "198.51.100.101"
  end

  test "v3 controller scope disambiguates duplicate cluster, node, and VMID tuples" do
    farm_host = host_row("host-farm", "pve-farm", @farm_controller_id, "shared", "pve01")
    tonka_host = host_row("host-tonka", "pve-tonka", @tonka_controller_id, "shared", "pve01")
    farm_guest = guest_row("guest-farm", "guest-farm", farm_host, "qemu", 155)
    tonka_guest = guest_row("guest-tonka", "guest-tonka", tonka_host, "qemu", 155)
    guests = [farm_guest, tonka_guest]

    lookup = fn
      VirtualizationHost, _uid, _ash_opts -> {:ok, []}
      VirtualizationGuest, _uid, _ash_opts -> {:ok, guests}
    end

    host_lookup = fn
      "host-farm", _ -> {:ok, farm_host}
      "host-tonka", _ -> {:ok, tonka_host}
    end

    device_lookup = fn
      "pve-farm", _ -> {:ok, controller_device("pve-farm", "192.0.2.10", farm_host)}
      "pve-tonka", _ -> {:ok, controller_device("pve-tonka", "198.51.100.10", tonka_host)}
    end

    opts = [
      virtualization_lookup: lookup,
      host_lookup: host_lookup,
      device_lookup: device_lookup
    ]

    assert {:ok, farm} =
             RemoteConsoleTargetResolver.resolve_proxmox(
               guest_device("guest-farm", nil, farm_guest),
               %{},
               opts
             )

    assert {:ok, tonka} =
             RemoteConsoleTargetResolver.resolve_proxmox(
               guest_device("guest-tonka", nil, tonka_guest),
               %{},
               opts
             )

    assert farm.controller_id == @farm_controller_id
    assert farm.controller.base_url == "https://192.0.2.10:8006"
    assert tonka.controller_id == @tonka_controller_id
    assert tonka.controller.base_url == "https://198.51.100.10:8006"
  end

  test "rejects multiple authoritative rows without exact v3 device scope" do
    farm_host = host_row("host-farm", "pve-farm", @farm_controller_id, "shared", "pve01")
    tonka_host = host_row("host-tonka", "pve-tonka", @tonka_controller_id, "shared", "pve01")

    lookup = fn
      VirtualizationHost, _uid, _ash_opts ->
        {:ok, []}

      VirtualizationGuest, _uid, _ash_opts ->
        {:ok,
         [
           guest_row("guest-farm", "ambiguous", farm_host, "qemu", 155),
           guest_row("guest-tonka", "ambiguous", tonka_host, "qemu", 155)
         ]}
    end

    assert {:error, :ambiguous_console_target} =
             RemoteConsoleTargetResolver.resolve_proxmox(
               %{uid: "ambiguous", metadata: %{}},
               %{},
               virtualization_lookup: lookup
             )
  end

  test "legacy native inventory is completed from a unique credential-rule source scope" do
    host = %{
      provider: "proxmox",
      provider_ref: "proxmox:node:pve02",
      device_uid: "sr:host-legacy",
      name: "pve02",
      identity_state: :legacy,
      native_cluster_id: "tonka",
      object_kind: "node",
      native_object_id: "pve02",
      metadata: %{}
    }

    lookup = fn
      VirtualizationHost, "sr:host-legacy", _ash_opts -> {:ok, [host]}
      VirtualizationGuest, "sr:host-legacy", _ash_opts -> flunk("guest lookup must not run")
    end

    assert {:ok, target} =
             RemoteConsoleTargetResolver.resolve_proxmox(
               %{
                 uid: "sr:host-legacy",
                 hostname: "pve02",
                 ip: "192.0.2.10",
                 agent_id: "agent-dusk01",
                 metadata: %{}
               },
               %{},
               virtualization_lookup: lookup,
               identity_scope: %{
                 integration_id: @integration_id,
                 controller_id: @farm_controller_id
               }
             )

    assert target.target_kind == :pve_host
    assert target.identity_version == 3
    assert target.identity_state == :authoritative
    assert target.integration_id == @integration_id
    assert target.controller_id == @farm_controller_id
    assert target.controller.base_url == "https://192.0.2.10:8006"
  end

  test "legacy v2 aliases are never authorized for native console" do
    lookup = fn
      VirtualizationHost, _uid, _ash_opts ->
        {:ok,
         [
           %{
             provider: "proxmox",
             provider_ref: "proxmox:node:pve01",
             device_uid: "legacy-pve",
             name: "pve01",
             metadata: %{"integration_id" => "proxmox:v2:farm01:node:pve01"}
           }
         ]}

      VirtualizationGuest, _uid, _ash_opts ->
        {:ok, []}
    end

    assert {:error, :unsupported_console_target} =
             RemoteConsoleTargetResolver.resolve_proxmox(
               %{uid: "legacy-pve", vendor_name: "Proxmox", ip: "192.0.2.10"},
               %{},
               virtualization_lookup: lookup
             )
  end

  test "inventory lookup failures never fall back to vendor or device IP" do
    lookup = fn _resource, _uid, _opts -> {:error, :db_unavailable} end

    assert {:error, :console_inventory_unavailable} =
             RemoteConsoleTargetResolver.resolve_proxmox(
               %{uid: "pve-fallback", vendor_name: "Proxmox", ip: "192.0.2.12"},
               %{},
               virtualization_lookup: lookup
             )
  end

  test "invalid or mismatched explicit controller origins fail closed" do
    host = host_row("host-farm", "pve-farm", @farm_controller_id, "farm01", "pve01")
    lookup = fn VirtualizationHost, _uid, _opts -> {:ok, [host]} end

    for explicit <- [
          "https://attacker.invalid:8006",
          "https://192.0.2.10:8006/api2/json",
          "https://192.0.2.10:99999",
          "https://192.0.2.10:not-a-port"
        ] do
      device =
        "pve-farm"
        |> controller_device("192.0.2.10", host)
        |> put_in([:metadata, "proxmox_base_url"], explicit)

      assert {:error, reason} =
               RemoteConsoleTargetResolver.resolve_proxmox(
                 device,
                 %{},
                 virtualization_lookup: lookup
               )

      assert reason in [:controller_origin_mismatch, :invalid_controller_origin]
    end
  end

  test "rejects an explicit cleartext Proxmox controller origin" do
    host = host_row("host-farm", "pve-farm", @farm_controller_id, "farm01", "pve01")
    lookup = fn VirtualizationHost, _uid, _opts -> {:ok, [host]} end

    device =
      "pve-farm"
      |> controller_device("192.0.2.10", host)
      |> put_in([:metadata, "proxmox_base_url"], "http://192.0.2.10:8006")

    assert {:error, :invalid_controller_origin} =
             RemoteConsoleTargetResolver.resolve_proxmox(
               device,
               %{},
               virtualization_lookup: lookup
             )
  end

  test "rejects hostname origins until trusted SNI and address pinning are available" do
    host = host_row("host-farm", "pve-farm", @farm_controller_id, "farm01", "pve01")
    lookup = fn VirtualizationHost, _uid, _opts -> {:ok, [host]} end

    device =
      "pve-farm"
      |> controller_device("192.0.2.10", host)
      |> put_in([:metadata, "proxmox_base_url"], "https://pve01:8006")

    assert {:error, :invalid_controller_origin} =
             RemoteConsoleTargetResolver.resolve_proxmox(
               device,
               %{},
               virtualization_lookup: lookup
             )
  end

  test "rejects a hostname-only controller even when inventory marks it authoritative" do
    host = host_row("host-farm", "pve-farm", @farm_controller_id, "farm01", "pve01")
    lookup = fn VirtualizationHost, _uid, _opts -> {:ok, [host]} end

    assert {:error, :console_controller_endpoint_missing} =
             RemoteConsoleTargetResolver.resolve_proxmox(
               controller_device("pve-farm", nil, host),
               %{},
               virtualization_lookup: lookup
             )
  end

  test "guest and owner must share the complete authoritative v3 source scope" do
    farm_host = host_row("host-farm", "pve-farm", @farm_controller_id, "farm01", "pve01")
    tonka_host = host_row("host-tonka", "pve-tonka", @tonka_controller_id, "tonka01", "pve01")
    guest = guest_row("guest-farm", "guest-farm", farm_host, "qemu", 155)

    lookup = fn
      VirtualizationHost, _uid, _opts -> {:ok, []}
      VirtualizationGuest, _uid, _opts -> {:ok, [guest]}
    end

    assert {:error, :console_controller_not_found} =
             RemoteConsoleTargetResolver.resolve_proxmox(
               guest_device("guest-farm", nil, guest),
               %{},
               virtualization_lookup: lookup,
               host_lookup: fn "host-farm", _ -> {:ok, tonka_host} end
             )
  end

  test "caller cannot override an authoritative host into a guest target" do
    host = host_row("host-farm", "pve-farm", @farm_controller_id, "farm01", "pve01")
    lookup = fn VirtualizationHost, _uid, _opts -> {:ok, [host]} end

    assert {:error, :unsupported_console_target} =
             RemoteConsoleTargetResolver.resolve_proxmox(
               controller_device("pve-farm", "192.0.2.10", host),
               %{"target_kind" => "qemu_guest"},
               virtualization_lookup: lookup
             )
  end

  test "rejects non-hypervisor devices without authoritative virtualization inventory" do
    lookup = fn _resource, _uid, _opts -> {:ok, []} end

    assert {:error, :unsupported_console_target} =
             RemoteConsoleTargetResolver.resolve_proxmox(
               %{uid: "switch-1", vendor_name: "Juniper"},
               %{},
               virtualization_lookup: lookup
             )
  end

  defp host_row(id, device_uid, controller_id, cluster, node) do
    {:ok, identity} =
      IntegrationIdentity.proxmox_v3_fields(
        @integration_id,
        controller_id,
        cluster,
        "node",
        node
      )

    Map.merge(identity, %{
      id: id,
      provider: "proxmox",
      device_uid: device_uid,
      name: node,
      metadata: %{}
    })
  end

  defp guest_row(id, device_uid, host, kind, vmid) do
    {:ok, identity} =
      IntegrationIdentity.proxmox_v3_fields(
        host.integration_id,
        host.controller_id,
        host.native_cluster_id,
        kind,
        vmid
      )

    Map.merge(identity, %{
      id: id,
      provider: "proxmox",
      host_id: host.id,
      device_uid: device_uid,
      name: "guest-#{vmid}",
      guest_type: kind,
      vmid: vmid,
      metadata: %{}
    })
  end

  defp controller_device(uid, ip, identity) do
    %{
      uid: uid,
      hostname: identity.native_object_id,
      ip: ip,
      agent_id: "agent-#{uid}",
      gateway_id: "gateway-#{uid}",
      vendor_name: "Proxmox",
      metadata: identity_metadata(identity)
    }
  end

  defp guest_device(uid, ip, identity) do
    %{
      uid: uid,
      hostname: "guest-#{identity.native_object_id}",
      ip: ip,
      vendor_name: "QEMU",
      metadata: identity_metadata(identity)
    }
  end

  defp identity_metadata(identity) do
    %{
      "provider_ref" => identity.provider_ref,
      "provider_instance_ref" => identity.provider_instance_ref,
      "integration_id" => identity.integration_id,
      "controller_id" => identity.controller_id,
      "native_cluster_id" => identity.native_cluster_id
    }
  end
end
