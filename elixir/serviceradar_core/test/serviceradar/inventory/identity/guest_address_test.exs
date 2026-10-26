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

  test "without a configuration source, guest-tools NICs win over host-internal networks" do
    interfaces = [
      %{name: "docker0", source: "guest_tools", ip_addresses: ["172.17.0.1/16"]},
      %{name: "ens5", source: "guest_tools", ip_addresses: ["172.30.0.1/24"]},
      %{name: "eth0", source: "guest_tools", ip_addresses: ["192.0.2.20/24"]}
    ]

    assert GuestAddress.primary(interfaces) == "192.0.2.20"
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
