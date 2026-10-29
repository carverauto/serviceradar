defmodule ServiceRadar.Inventory.Identity.HostInterfaces do
  @moduledoc """
  Identity eligibility for an agent's own interface inventory.

  The agent reports every local interface it has (`HostInterface` in
  `proto/monitoring.proto`) with the operating system's classification: its kind
  (physical, bond, bridge, VLAN, virtual, tunnel), its current MAC and how that MAC
  was assigned, the NIC's permanent MAC when the platform reports one, and its
  addresses. The agent classifies; this module decides identity.

  From the inventory, only the permanent, globally administered MAC of a physical NIC is strong
  identity. A bond member is a physical NIC whose permanent MAC the agent reads from
  `perm_hwaddr`, so it counts the same way. Nothing else does:

  - a bridge, bond or VLAN carries a MAC it took from a port, and the port counts
    on its own, so the bridge never adds an identity of its own;
  - a veth, tap, dummy, macvlan or SR-IOV virtual function is `virtual`, and its MAC
    is a guest's, a container's or the kernel's;
  - a MAC the kernel randomized or software set has no permanent MAC behind it;
  - a locally administered, multicast or reserved MAC identifies nothing.

  The interfaces' addresses are corroborating evidence only (`host_ips/1`): they
  never link the agent to a device on their own.

  An inventory in which no interface was classified comes from a platform that
  cannot classify (every agent outside Linux reports kinds as unspecified), and
  `eligible_macs/1` answers `:unclassified`: the caller then keeps the announced
  interface's MAC (`host_macs`), as before the inventory existed. The caller also
  uses that fallback when a classified inventory returns `{:ok, []}`: containers
  and other guests without an eligible physical NIC retain their announced MAC.
  Both fallback paths exclude locally administered, multicast and reserved MACs.
  Whenever any eligible physical MAC exists, only the inventory MACs are used;
  a hypervisor therefore cannot claim its guests' tap or veth MACs.
  """

  alias ServiceRadar.Inventory.Identity.Mac

  @kinds %{
    1 => :physical,
    2 => :bond,
    3 => :bridge,
    4 => :vlan,
    5 => :virtual,
    6 => :tunnel,
    7 => :loopback
  }

  @kind_names Map.new(@kinds, fn {_number, kind} ->
                {"HOST_INTERFACE_KIND_" <> String.upcase(Atom.to_string(kind)), kind}
              end)

  @classified_kinds [:physical, :bond, :bridge, :vlan, :virtual, :tunnel]

  @type interface :: %{
          name: String.t() | nil,
          kind: atom(),
          permanent_mac: String.t() | nil,
          ips: [String.t()]
        }

  @doc """
  The inventory as reported, each entry a map with `:name`, `:kind` (an atom,
  `:unspecified` when the platform could not tell), `:permanent_mac` (normalized, or
  nil) and `:ips`. Accepts the gateway's maps, with enum values as atoms, numbers or
  names, under atom or string keys. Anything that is not a map is dropped.
  """
  @spec normalize(term()) :: [interface()]
  def normalize(interfaces) when is_list(interfaces) do
    for %{} = iface <- interfaces do
      %{
        name: field(iface, :name),
        kind: kind(field(iface, :kind)),
        permanent_mac: Mac.normalize_mac(field(iface, :permanent_mac)),
        ips: iface |> field(:ips) |> List.wrap() |> Enum.filter(&is_binary/1)
      }
    end
  end

  def normalize(_interfaces), do: []

  @doc """
  The MACs in the inventory that identify the host, normalized, or `:unclassified`
  when no interface was classified.
  """
  @spec eligible_macs([interface()]) :: {:ok, [String.t()]} | :unclassified
  def eligible_macs(interfaces) do
    if Enum.any?(interfaces, &(&1.kind in @classified_kinds)) do
      {:ok,
       interfaces
       |> Enum.filter(&(&1.kind == :physical))
       |> Enum.map(& &1.permanent_mac)
       |> Enum.filter(&identity_mac?/1)
       |> Enum.uniq()}
    else
      :unclassified
    end
  end

  @doc """
  Every routable address the inventory reports, sorted: corroborating address
  evidence, never identity. Loopback, link-local, unspecified and multicast
  addresses are left out.
  """
  @spec host_ips([interface()]) :: [String.t()]
  def host_ips(interfaces) do
    interfaces
    |> Enum.reject(&(&1.kind == :loopback))
    |> Enum.flat_map(& &1.ips)
    |> Enum.flat_map(&routable_ip/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp identity_mac?(nil), do: false

  defp identity_mac?(mac) do
    not Mac.reserved_mac_value?(mac) and not Mac.multicast_mac?(mac) and
      not Mac.locally_administered_mac?(mac)
  end

  defp routable_ip(text) do
    case :inet.parse_strict_address(String.to_charlist(String.trim(text))) do
      {:ok, address} -> if routable?(address), do: [to_string(:inet.ntoa(address))], else: []
      {:error, _reason} -> []
    end
  end

  defp routable?({127, _, _, _}), do: false
  defp routable?({0, 0, 0, 0}), do: false
  defp routable?({169, 254, _, _}), do: false
  defp routable?({a, _, _, _}) when a >= 224, do: false
  defp routable?({0, 0, 0, 0, 0, 0, 0, 0}), do: false
  defp routable?({0, 0, 0, 0, 0, 0, 0, 1}), do: false
  defp routable?({a, _, _, _, _, _, _, _}) when a >= 0xFE80 and a <= 0xFEBF, do: false
  defp routable?({a, _, _, _, _, _, _, _}) when a >= 0xFF00, do: false
  defp routable?(_address), do: true

  defp kind(value) when is_integer(value), do: Map.get(@kinds, value, :unspecified)

  defp kind(value) when is_atom(value) and not is_nil(value), do: kind(Atom.to_string(value))

  defp kind(value) when is_binary(value) do
    normalized = value |> String.trim() |> String.upcase()

    Map.get(@kind_names, normalized) ||
      Map.get(@kind_names, "HOST_INTERFACE_KIND_" <> normalized, :unspecified)
  end

  defp kind(_value), do: :unspecified

  defp field(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
end
