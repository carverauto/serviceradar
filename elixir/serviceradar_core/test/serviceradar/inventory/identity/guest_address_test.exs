defmodule ServiceRadar.Inventory.Identity.GuestAddressTest do
  @moduledoc """
  Which guest interface address becomes the device's primary IP.

  The hypervisor enrichment ingestor writes this choice onto the device row,
  and the row's rank guard cannot undo it: a container bridge gateway ranks
  as "private", the same as the LAN address it displaces. So a host-internal
  address that wins here is the address the device presents.
  """
  use ExUnit.Case, async: true

  alias ServiceRadar.Inventory.Identity.GuestAddress

  test "a container bridge reported ahead of the hypervisor NIC does not become primary" do
    # Report order is not a preference: the adapter can list a guest-agent-only
    # bridge first. The bridge carries a gateway address in Docker's default
    # range under a name that matches no bridge naming convention.
    interfaces = [
      %{name: "app-bridge", source: "guest_agent", ip_addresses: ["172.17.0.1/16"]},
      %{name: "net0", source: "config,guest_agent", ip_addresses: ["192.0.2.10/24"]}
    ]

    assert GuestAddress.primary(interfaces) == "192.0.2.10"
  end

  test "a dual-homed guest's primary is its lowest configured NIC, whatever the report order" do
    # Report order is the connector's, not the guest config's. The Proxmox
    # connector carries the config key (`netN`) in each record's metadata;
    # that index is the guest's NIC order.
    second_nic_first = [
      %{
        name: "eth1",
        source: "config",
        ip_addresses: ["198.51.100.14/24"],
        metadata: %{"config_key" => "net1"}
      },
      %{
        name: "eth0",
        source: "config",
        ip_addresses: ["192.0.2.14/24"],
        metadata: %{"config_key" => "net0"}
      }
    ]

    assert GuestAddress.primary(second_nic_first) == "192.0.2.14"

    # The index is numeric: net10 is configured after net2.
    without_net0 = [
      %{name: "eth10", source: "config", ip_addresses: ["198.51.100.30/24"], config_key: "net10"},
      %{name: "eth2", source: "config", ip_addresses: ["192.0.2.30/24"], config_key: "net2"}
    ]

    assert GuestAddress.primary(without_net0) == "192.0.2.30"
  end

  test "without a configuration source, guest-tools NICs win over host-internal networks" do
    interfaces = [
      %{name: "docker0", source: "guest_tools", ip_addresses: ["172.17.0.1/16"]},
      %{name: "ens5", source: "guest_tools", ip_addresses: ["172.30.0.1/24"]},
      %{name: "eth0", source: "guest_tools", ip_addresses: ["192.0.2.20/24"]}
    ]

    assert GuestAddress.primary(interfaces) == "192.0.2.20"
  end

  # The device's MAC is the MAC of the interface its address comes from, which is
  # not the first interface in preference order when that one has no accepted
  # address. Invented MACs under the Proxmox OUI.
  test "primary_interface/1 is the interface primary/1 takes the address from" do
    awaiting_lease = [
      %{
        name: "mgmt",
        source: "config",
        mac_address: "BC:24:11:0F:00:01",
        ip_addresses: ["dhcp"],
        config_key: "net0"
      },
      %{
        name: "data",
        source: "config",
        mac_address: "BC:24:11:0F:00:02",
        ip_addresses: ["192.0.2.10/24"],
        config_key: "net1"
      }
    ]

    assert %{mac_address: "BC:24:11:0F:00:02"} = GuestAddress.primary_interface(awaiting_lease)
    assert GuestAddress.primary(awaiting_lease) == "192.0.2.10"

    guest_tools = [
      %{
        name: "ens5",
        source: "guest_tools",
        mac_address: "BC:24:11:0F:00:05",
        ip_addresses: ["172.30.0.1/24"]
      },
      %{
        name: "eth0",
        source: "guest_tools",
        mac_address: "BC:24:11:0F:00:06",
        ip_addresses: ["192.0.2.20/24"]
      }
    ]

    assert %{mac_address: "BC:24:11:0F:00:06"} = GuestAddress.primary_interface(guest_tools)

    only_bridge = [%{name: "docker0", ip_addresses: ["172.17.0.1/16"]}]
    assert GuestAddress.primary_interface(only_bridge) == nil
  end

  test "a guest that reports only host-internal networks has no primary address" do
    interfaces = [
      %{name: "vxlan.calico", source: "guest_agent", ip_addresses: ["198.51.100.64/32"]},
      %{name: "br-0a1b2c3d4e5f", source: "guest_agent", ip_addresses: ["198.51.100.129/25"]}
    ]

    assert GuestAddress.primary(interfaces) == nil
  end

  test "host_internal_address?/2 flags bridge, CNI, and own-prefix gateway addresses unless hypervisor-attached" do
    assert GuestAddress.host_internal_address?(
             %{name: "docker0", source: "guest_agent"},
             "172.17.0.1/16"
           )

    assert GuestAddress.host_internal_address?(
             %{name: "br-0a1b2c3d4e5f", source: "guest_agent"},
             "198.51.100.10/24"
           )

    assert GuestAddress.host_internal_address?(
             %{name: "ens5", source: "guest_tools", cidr: "172.30.0.1/24"},
             "172.30.0.1"
           )

    refute GuestAddress.host_internal_address?(
             %{name: "eth0", source: "guest_tools"},
             "192.0.2.20/24"
           )

    refute GuestAddress.host_internal_address?(
             %{name: "net0", source: "config,guest_agent"},
             "172.17.0.1/16"
           )
  end

  test "a plus-joined source is not the hypervisor configuration source" do
    # Producers join interface sources with a comma. `config+agent` is one
    # token, so a bridge listed that way stays host-internal and cannot win.
    interfaces = [
      %{name: "br-lan0", source: "config+agent", ip_addresses: ["203.0.113.10/24"]},
      %{name: "eth0", source: "guest_agent", ip_addresses: ["192.0.2.10/24"]}
    ]

    assert GuestAddress.primary(interfaces) == "192.0.2.10"
  end
end
