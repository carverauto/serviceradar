defmodule ServiceRadar.Inventory.Identity.GuestAddress do
  @moduledoc """
  Which of a virtual guest's interface addresses is its PRIMARY address.

  A hypervisor reports two kinds of interface for a guest. The NICs the
  hypervisor attached to it carry the address the rest of the network reaches
  the guest on. The guest agent also reports every network the guest runs for
  itself: a container engine's bridges, a CNI overlay, veth pairs. Those
  host-internal addresses are reachable only from inside the guest and repeat
  across guests, because every container host can carry the same default
  bridge gateway. They must never become a device's primary address.

  Picking the first interface in report order did exactly that: a guest whose
  container bridge happened to be listed ahead of its NIC presented the
  bridge gateway as its address, and an inventory query by the guest's real
  address stopped matching it.

  `DeviceWrites` cannot catch this on its own. It ranks an incoming address by
  class (`Address.rank/1`), and a bridge gateway is as "private" as the LAN
  address it displaces, so equal rank lets it through. The choice has to be
  made here, while the interface context still exists.

  Preference, strongest first:

    1. a hypervisor-attached NIC: its record `source` lists `config`, which the
       Proxmox connector sets on every NIC defined in the guest's configuration;
    2. any other interface that is not host-internal, for providers whose
       guest tools report the NIC without a configuration source. Host-internal
       means, by address role and never by a deployment's numbering: named like
       a container, CNI, or local-hypervisor bridge (`docker0`, `br-*`, `cni*`,
       `flannel*`, `veth*`, `virbr*`, `cali*`, ...); inside Docker's default
       bridge network (`172.17.0.0/16`); or the first host of its own prefix,
       the gateway a host assigns itself on a bridge it creates.

  Among hypervisor-attached NICs, the guest's configured NIC order decides: the
  lowest configuration index (`net0`, then `net1`, ... compared as numbers),
  read from the record's `config_key`, top-level or in its `metadata`. A
  dual-homed guest therefore presents the NIC its configuration lists first,
  and its other NICs stay secondary. Report order cannot carry that preference:
  a connector need not list NICs by index (`net10` sorts before `net2` as
  text), and interface names are the guest's own choice (`mgmt`, `data`). An
  attached NIC without a configuration index ranks after the indexed ones.

  Across those interfaces the strongest address wins first (`Address.strength/1`:
  a usable IPv4 over any IPv6, a routable address over a link-local), so the
  order above decides only among equally strong addresses. Otherwise report
  order decides, and an interface contributes its strongest address (the first
  of equally strong ones), so a guest that never carried a host-internal address
  keeps the address it had. `nil` when no interface qualifies: callers keep the device's
  current address rather than taking a host-internal one.

  `preference_order/1` is that ordering on its own, and `primary_interface/1`
  the interface the address comes from. The device's MAC must come from the
  same NIC as its address, so whoever picks a guest's MAC takes that
  interface's MAC first rather than applying a rule of its own.
  """

  import Bitwise

  alias Palisade.NetworkAddressPolicy
  alias ServiceRadar.Inventory.Identity.Address

  # Interface names container engines, CNI plugins, and local hypervisors give
  # the networks they create inside a host.
  @host_internal_name_prefixes [
    "docker",
    "br-",
    "cni",
    "flannel",
    "veth",
    "virbr",
    "cali",
    "vxlan",
    "tunl",
    "cilium",
    "kube-",
    "weave",
    "podman",
    "lxcbr",
    "lxdbr"
  ]

  # Docker's default bridge network.
  @docker_default_bridge "172.17.0.0/16"

  # /31 (point-to-point) and /32 (host route) have no network-plus-one gateway.
  @max_gateway_prefix 30

  @placeholder_addresses ["dhcp", "auto", "manual", "none"]

  @doc """
  The guest's primary address among `interfaces`, or `nil`.

  Each interface is a map with any of `:name`, `:source`, `:config_key`,
  `:metadata`, `:ip_addresses`, `:cidr`, and `:address` (atom or string keys).
  """
  @spec primary([map()]) :: String.t() | nil
  def primary(interfaces) do
    case primary_interface(interfaces) do
      nil -> nil
      iface -> iface |> interface_address() |> strip_prefix()
    end
  end

  @doc """
  The interface `primary/1` takes the guest's address from, or `nil`.

  The device's MAC is this interface's MAC: the first interface in
  `preference_order/1` whose address is accepted. That need not be the first
  interface in the order: a lowest-indexed NIC with no usable address (`dhcp`
  before a lease is reported), or a guest-tools interface whose address is
  host-internal, is passed over for the address, and so for the MAC.
  """
  @spec primary_interface([map()]) :: map() | nil
  def primary_interface(interfaces) when is_list(interfaces) do
    interfaces
    |> preference_order()
    |> Enum.filter(&accepted_address?/1)
    |> case do
      [] -> nil
      # The strongest address wins (`Address.strength/1`: a usable IPv4 over any
      # IPv6, a routable address over a link-local); among equally strong ones the
      # preference order decides, `Enum.max_by/2` keeping the first.
      accepted -> Enum.max_by(accepted, &(&1 |> interface_address() |> address_strength()))
    end
  end

  def primary_interface(_interfaces), do: nil

  @doc """
  One guest's `interfaces`, most preferred first: hypervisor-attached NICs by
  configured index (unindexed ones after them), then every other interface.
  Ties, and the other interfaces, keep report order.

  This orders interfaces and filters none; `primary_interface/1` is the first
  interface in this order whose address `primary/1` accepts.
  """
  @spec preference_order([map()]) :: [map()]
  def preference_order(interfaces) when is_list(interfaces) do
    {attached, other} = Enum.split_with(interfaces, &hypervisor_attached?/1)
    Enum.sort_by(attached, &configured_order/1) ++ other
  end

  # `{0, n}` for the NIC configured as `net<n>`; `{1, 0}` for one without a
  # configuration index, so it follows every indexed NIC. `Enum.sort_by/2` is
  # stable, so equal keys keep report order.
  defp configured_order(iface) do
    with "net" <> digits <- config_key(iface),
         {index, ""} when index >= 0 <- Integer.parse(digits) do
      {0, index}
    else
      _ -> {1, 0}
    end
  end

  defp config_key(iface) do
    case {field(iface, :config_key), field(iface, :metadata)} do
      {key, _metadata} when is_binary(key) -> key
      {_key, metadata} when is_map(metadata) -> field(metadata, :config_key)
      _ -> nil
    end
  end

  @doc """
  Whether `address` on `iface` belongs to a network the guest runs for itself
  rather than one the hypervisor attached it to.

  Hypervisor-attached interfaces (`source` lists `"config"`) are never
  classified as host-internal. For other interfaces, an address is
  host-internal when the interface name matches a container/CNI/local-hypervisor
  bridge prefix (`docker0`, `br-<hex>`, `cni*`, `veth*`, ...), the address lies
  in Docker's default bridge network (`172.17.0.0/16`), or the address is the
  first host of its own prefix (`172.18.0.1/16`).
  """
  @spec host_internal_address?(map(), term()) :: boolean()
  def host_internal_address?(iface, address) when is_map(iface) and is_binary(address) do
    not hypervisor_attached?(iface) and host_internal?(iface, address)
  end

  def host_internal_address?(_iface, _address), do: false

  # Whether `address` on `iface` belongs to a network the guest runs for itself
  # rather than one the hypervisor attached it to. By address role, never by a
  # deployment's numbering: a container/CNI/local-hypervisor bridge name, Docker's
  # default bridge network, or the first host of the address's own prefix (the
  # gateway a host assigns itself on a bridge it creates, `172.18.0.1/16`).
  defp host_internal?(iface, address) do
    address = address_with_interface_prefix(iface, address)

    host_internal_name?(field(iface, :name)) or docker_default_bridge?(address) or
      own_prefix_gateway?(address)
  end

  defp address_with_interface_prefix(iface, address) do
    if String.contains?(address, "/") do
      address
    else
      case field(iface, :cidr) do
        cidr when is_binary(cidr) ->
          if String.contains?(cidr, "/") and strip_prefix(cidr) == strip_prefix(address),
            do: String.trim(cidr),
            else: address

        _ ->
          address
      end
    end
  end

  @doc """
  Whether the hypervisor attached `iface` to the guest: its `source` lists
  `config`, which the Proxmox connector sets on every NIC defined in the
  guest's configuration.
  """
  @spec hypervisor_attached?(map()) :: boolean()
  def hypervisor_attached?(iface) when is_map(iface) do
    iface
    |> field(:source)
    |> to_string()
    |> String.split(",", trim: true)
    |> Enum.any?(&(String.trim(&1) == "config"))
  end

  # A hypervisor-attached NIC's address is always accepted; any other
  # interface's only when it is not host-internal.
  defp accepted_address?(iface) do
    case interface_address(iface) do
      nil -> false
      address -> hypervisor_attached?(iface) or not host_internal?(iface, address)
    end
  end

  # An interface's own address, prefix kept so `own_prefix_gateway?/1` can
  # judge it: the strongest usable entry of `ip_addresses`, then `cidr`, then
  # `address` (`Address.strength/1`), the first of equally strong ones.
  defp interface_address(iface) do
    iface
    |> field(:ip_addresses)
    |> List.wrap()
    |> Enum.concat([field(iface, :cidr), field(iface, :address)])
    |> Enum.map(&usable_address/1)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      addresses -> Enum.max_by(addresses, &address_strength/1)
    end
  end

  defp address_strength(nil), do: -1
  defp address_strength(address), do: address |> strip_prefix() |> Address.strength()

  defp usable_address(value) when is_binary(value) do
    value = String.trim(value)

    if strip_prefix(value) == "" or String.downcase(value) in @placeholder_addresses,
      do: nil,
      else: value
  end

  defp usable_address(_value), do: nil

  @doc """
  Whether an interface `name` belongs to a container engine, CNI overlay, or
  local-hypervisor bridge (`docker0`, `br-<hex>`, `cni*`, `veth*`, ...).
  """
  @spec host_internal_name?(term()) :: boolean()
  def host_internal_name?(name) when is_binary(name) do
    String.starts_with?(String.downcase(String.trim(name)), @host_internal_name_prefixes)
  end

  def host_internal_name?(_name), do: false

  @doc """
  SQL boolean expression matching `host_internal_name?/1` on `column_expr`.
  """
  @spec host_internal_name_sql(String.t()) :: String.t()
  def host_internal_name_sql(column_expr) when is_binary(column_expr) do
    prefixes = Enum.map_join(@host_internal_name_prefixes, ", ", &"'#{&1}'")

    String.trim("""
    EXISTS (
      SELECT 1
      FROM unnest(ARRAY[#{prefixes}]::text[]) AS prefix
      WHERE starts_with(lower(btrim(COALESCE(#{column_expr}, ''))), prefix)
    )
    """)
  end

  defp docker_default_bridge?(address) do
    case parse_ipv4(strip_prefix(address)) do
      {:ok, ip} -> NetworkAddressPolicy.cidr_contains?(ip, @docker_default_bridge)
      :error -> false
    end
  end

  defp own_prefix_gateway?(address) do
    with [ip_text, prefix_text] <- String.split(address, "/", parts: 2),
         {:ok, {a, b, c, d}} <- parse_ipv4(ip_text),
         {prefix_len, ""} when prefix_len in 1..@max_gateway_prefix <-
           Integer.parse(String.trim(prefix_text)) do
      host_bits = (1 <<< (32 - prefix_len)) - 1
      ((a <<< 24 ||| b <<< 16 ||| c <<< 8 ||| d) &&& host_bits) == 1
    else
      _ -> false
    end
  end

  defp parse_ipv4(text) do
    case :inet.parse_ipv4strict_address(String.to_charlist(String.trim(text))) do
      {:ok, ip} -> {:ok, ip}
      {:error, _reason} -> :error
    end
  end

  defp strip_prefix(value) do
    value |> String.split("/", parts: 2) |> hd() |> String.trim()
  end

  defp field(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
end
