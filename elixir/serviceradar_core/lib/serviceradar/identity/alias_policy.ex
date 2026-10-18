defmodule ServiceRadar.Identity.AliasPolicy do
  @moduledoc """
  Which addresses may be recorded as device aliases.

  Aliases are what DIRE merges devices on, so this predicate is an identity
  control, not a formatting nicety: an address that many devices share must
  never become an alias, or every device carrying it collapses into one.

  This exists as a shared module because the rule was previously enforced in
  exactly one of the two producers. `MapperResultsIngestor` filtered, while the
  `AliasEvents` path -- which is fed by the netprobe NDP census and produces
  every IPv6 alias in the fleet today -- applied no gate at all. The result was
  33 of 40 IPv6 aliases on farm01 being `fe80::` link-local. One predicate, both
  callers.
  """

  import Bitwise

  alias ServiceRadar.Inventory.Identity.Address
  alias ServiceRadar.Repo

  @aliasable_classes [:global, :private, :unique_local]
  @max_broadcast_prefix 30
  @ipv4_max_u32 0xFFFF_FFFF

  @doc """
  Whether `value` may be stored as a device alias.

  Rejected, and why each matters for identity rather than tidiness:

    * loopback (`127/8`, `::1`) -- every device has it
    * unspecified (`0.0.0.0`, `::`) -- a placeholder, not an address
    * link-local (`fe80::/10`, `169.254/16`) -- an interface property. A vendor
      that assigns a fixed `fe80::1` to every router would otherwise merge all
      of them into one device. IPv4 link-local is APIPA, which means "this host
      failed DHCP" and identifies nothing.
    * broadcast (`255.255.255.255`, or an IPv4 directed broadcast address for a
      subnet with prefix length `0..30`, such as `192.0.2.255/24` or
      `198.51.101.255` in `198.51.100.0/23`) -- shared by every host on the
      subnet, and emitted by Net-SNMP `ipAddressTable` alongside the unicast
      interface address. Confirming a subnet broadcast as an `:ip` alias turns a
      shared subnet property into merge evidence (GitHub #5743).

  Link-local addresses remain valid on interface records; they are only barred
  from being device *aliases*. Broadcast addresses are neither host interfaces
  nor aliases.

  Classification uses `Inventory.Identity.Address.classify/1` plus
  `broadcast_ip?/2` so `Address.rank/1` stays in strict parity with SQL
  `platform.sr_address_rank(text)`.
  """
  @spec valid_alias_ip?(term(), Enumerable.t()) :: boolean()
  def valid_alias_ip?(value, known_cidrs \\ [])

  def valid_alias_ip?(value, known_cidrs) when is_binary(value) do
    Address.classify(value) in @aliasable_classes and not broadcast_ip?(value, known_cidrs)
  end

  def valid_alias_ip?(_value, _known_cidrs), do: false

  @doc """
  Whether `value` is the IPv4 limited broadcast (`255.255.255.255`) or the
  directed broadcast address of an IPv4 subnet with prefix length `0..30`
  (either self-described as `a.b.c.d/len` or matched against `known_cidrs`).

  `/31` (RFC 3021 point-to-point) and `/32` (host route) have no directed
  broadcast address, and a valid `.255` host inside a wider prefix (such as
  `203.0.1.255` in `203.0.0.0/16`) is not the broadcast of `/16`
  (`203.0.255.255`).
  """
  @spec broadcast_ip?(term(), Enumerable.t()) :: boolean()
  def broadcast_ip?(value, known_cidrs \\ [])

  def broadcast_ip?(value, known_cidrs) when is_binary(value) do
    case parse_ipv4_value(value) do
      {:ok, {255, 255, 255, 255}, _prefix_len} ->
        true

      {:ok, _ip4, prefix_len} when is_integer(prefix_len) and prefix_len in 31..32 ->
        false

      {:ok, ip4, prefix_len}
      when is_integer(prefix_len) and prefix_len in 0..@max_broadcast_prefix ->
        directed_broadcast_for_prefix?(ip4, ip4, prefix_len)

      {:ok, ip4, nil} ->
        Enum.any?(known_cidrs, &directed_broadcast_in_cidr?(ip4, &1))

      :error ->
        false
    end
  end

  def broadcast_ip?(_value, _known_cidrs), do: false

  @doc """
  Extracts known IPv4 subnet CIDRs for a single interface from its `ip_addresses`
  list and `metadata` map (`"ip_cidrs"`, `"cidr"`, `"subnet"`), falling back to a
  `/24` subnet only when the same interface carries both a `.255` address and a
  sibling `.1..254` host in the same `/24` with no explicit CIDR covering that
  address.
  """
  @spec interface_known_cidrs(term(), term()) :: [String.t()]
  def interface_known_cidrs(ip_addresses, metadata \\ %{}) do
    ips = List.wrap(ip_addresses)
    meta = if is_map(metadata), do: metadata, else: %{}

    explicit_cidrs =
      Enum.uniq(explicit_cidrs_from_list(ips) ++ explicit_cidrs_from_metadata(meta))

    inferred_cidrs = infer_same_interface_pair_cidrs(ips, explicit_cidrs)

    Enum.uniq(explicit_cidrs ++ inferred_cidrs)
  end

  @doc """
  Loads known IPv4 subnet CIDRs for a single device from its persisted
  `virtualization_network_interfaces`, latest `discovered_interfaces`, and optional
  metadata map.
  """
  @spec known_cidrs_for_device(term(), term()) :: [String.t()]
  def known_cidrs_for_device(device_id, metadata \\ %{}) do
    meta_cidrs = if is_map(metadata), do: explicit_cidrs_from_metadata(metadata), else: []

    db_cidrs =
      case normalize_device_id(device_id) do
        nil ->
          []

        uid ->
          [uid]
          |> known_cidrs_by_device_ids()
          |> Map.get(uid, [])
      end

    Enum.uniq(meta_cidrs ++ db_cidrs)
  end

  @doc """
  Batch-loads known IPv4 subnet CIDRs keyed by `device_id` from
  `platform.virtualization_network_interfaces` and the latest
  `platform.discovered_interfaces` snapshot per interface.
  """
  @spec known_cidrs_by_device_ids(Enumerable.t()) :: %{optional(String.t()) => [String.t()]}
  def known_cidrs_by_device_ids(device_ids) do
    uids =
      device_ids
      |> Enum.map(&normalize_device_id/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    if uids == [] do
      %{}
    else
      vnic_cidrs = query_vnic_cidrs(uids)
      iface_cidrs = query_discovered_interface_cidrs(uids)

      uids
      |> Map.new(fn uid ->
        cidrs = Enum.uniq(Map.get(vnic_cidrs, uid, []) ++ Map.get(iface_cidrs, uid, []))

        {uid, cidrs}
      end)
      |> Map.reject(fn {_uid, cidrs} -> cidrs == [] end)
    end
  rescue
    _ -> %{}
  catch
    :exit, _ -> %{}
  end

  defp query_vnic_cidrs(uids) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT DISTINCT device_uid, cidr
        FROM platform.virtualization_network_interfaces
        WHERE device_uid = ANY($1::text[])
          AND cidr IS NOT NULL
          AND btrim(cidr) <> ''
        """,
        [uids]
      )

    Enum.reduce(rows, %{}, fn [device_uid, cidr], acc ->
      case normalize_ipv4_cidr(cidr) do
        nil -> acc
        normalized -> Map.update(acc, device_uid, [normalized], &[normalized | &1])
      end
    end)
  rescue
    _ -> %{}
  catch
    :exit, _ -> %{}
  end

  defp query_discovered_interface_cidrs(uids) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT DISTINCT ON (device_id, interface_uid)
          device_id,
          COALESCE(ip_addresses, ARRAY[]::text[]),
          COALESCE(metadata, '{}'::jsonb)
        FROM platform.discovered_interfaces
        WHERE device_id = ANY($1::text[])
        ORDER BY device_id, interface_uid, timestamp DESC
        """,
        [uids]
      )

    Enum.reduce(rows, %{}, fn [device_id, ip_addresses, metadata], acc ->
      cidrs = interface_known_cidrs(ip_addresses, metadata)

      if cidrs == [] do
        acc
      else
        Map.update(acc, device_id, cidrs, &Enum.uniq(&1 ++ cidrs))
      end
    end)
  rescue
    _ -> %{}
  catch
    :exit, _ -> %{}
  end

  defp normalize_device_id(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_device_id(_), do: nil

  defp explicit_cidrs_from_list(values) when is_list(values) do
    values
    |> Enum.flat_map(&split_cidr_tokens/1)
    |> Enum.map(&normalize_ipv4_cidr/1)
    |> Enum.reject(&is_nil/1)
  end

  defp explicit_cidrs_from_list(_), do: []

  defp explicit_cidrs_from_metadata(metadata) when is_map(metadata) do
    ["ip_cidrs", :ip_cidrs, "cidr", :cidr, "subnet", :subnet]
    |> Enum.flat_map(fn key ->
      case Map.get(metadata, key) do
        value when is_binary(value) -> split_cidr_tokens(value)
        value when is_list(value) -> Enum.flat_map(value, &split_cidr_tokens/1)
        _ -> []
      end
    end)
    |> Enum.map(&normalize_ipv4_cidr/1)
    |> Enum.reject(&is_nil/1)
  end

  defp explicit_cidrs_from_metadata(_), do: []

  defp split_cidr_tokens(value) when is_binary(value) do
    value
    |> String.split([",", " "], trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&String.contains?(&1, "/"))
  end

  defp split_cidr_tokens(_), do: []

  defp normalize_ipv4_cidr(value) when is_binary(value) do
    case parse_ipv4_value(value) do
      {:ok, {a, b, c, d}, prefix_len} when is_integer(prefix_len) and prefix_len in 0..32 ->
        "#{a}.#{b}.#{c}.#{d}/#{prefix_len}"

      _ ->
        nil
    end
  end

  defp normalize_ipv4_cidr(_), do: nil

  defp infer_same_interface_pair_cidrs(ip_addresses, explicit_cidrs) do
    parsed_ips =
      ip_addresses
      |> Enum.flat_map(fn ip ->
        case parse_ipv4_value(ip) do
          {:ok, ip4, nil} -> [ip4]
          _ -> []
        end
      end)
      |> Enum.uniq()

    parsed_ips
    |> Enum.filter(fn {_a, _b, _c, d} = ip4 ->
      d == 255 and ip4 != {255, 255, 255, 255} and
        not Enum.any?(explicit_cidrs, &cidr_contains_ip?(ip4, &1))
    end)
    |> Enum.flat_map(fn {a, b, c, 255} ->
      has_sibling_host? =
        Enum.any?(parsed_ips, fn
          {^a, ^b, ^c, host_d} when host_d in 1..254 -> true
          _ -> false
        end)

      if has_sibling_host? do
        ["#{a}.#{b}.#{c}.0/24"]
      else
        []
      end
    end)
  end

  defp directed_broadcast_in_cidr?(ip4, cidr) when is_binary(cidr) do
    case parse_ipv4_value(cidr) do
      {:ok, net4, prefix_len}
      when is_integer(prefix_len) and prefix_len in 0..@max_broadcast_prefix ->
        directed_broadcast_for_prefix?(ip4, net4, prefix_len)

      _ ->
        false
    end
  end

  defp directed_broadcast_in_cidr?(_ip4, _cidr), do: false

  defp cidr_contains_ip?(ip4, cidr) when is_binary(cidr) do
    case parse_ipv4_value(cidr) do
      {:ok, net4, prefix_len} when is_integer(prefix_len) and prefix_len in 0..32 ->
        mask = ipv4_netmask_u32(prefix_len)
        (ipv4_to_u32(ip4) &&& mask) == (ipv4_to_u32(net4) &&& mask)

      _ ->
        false
    end
  end

  defp directed_broadcast_for_prefix?(ip4, net4, prefix_len)
       when prefix_len in 0..@max_broadcast_prefix do
    host_mask = ipv4_hostmask_u32(prefix_len)
    net_mask = bxor(@ipv4_max_u32, host_mask)
    broadcast_u32 = bor(band(ipv4_to_u32(net4), net_mask), host_mask)
    ipv4_to_u32(ip4) == broadcast_u32
  end

  defp ipv4_hostmask_u32(0), do: @ipv4_max_u32
  defp ipv4_hostmask_u32(prefix_len) when prefix_len in 1..31, do: (1 <<< (32 - prefix_len)) - 1
  defp ipv4_hostmask_u32(32), do: 0

  defp ipv4_netmask_u32(prefix_len), do: bxor(@ipv4_max_u32, ipv4_hostmask_u32(prefix_len))

  defp ipv4_to_u32({a, b, c, d}) do
    a <<< 24 ||| b <<< 16 ||| c <<< 8 ||| d
  end

  defp parse_ipv4_value(value) when is_binary(value) do
    without_zone =
      value
      |> String.trim()
      |> String.split("%", parts: 2)
      |> hd()

    case String.split(without_zone, "/", parts: 2) do
      [addr_str] ->
        case parse_ipv4_address(addr_str) do
          {:ok, ip4, _mapped?} -> {:ok, ip4, nil}
          :error -> :error
        end

      [addr_str, prefix_str] ->
        with {:ok, ip4, mapped?} <- parse_ipv4_address(addr_str),
             {:ok, prefix_len} <- parse_prefix_length(prefix_str, mapped?) do
          {:ok, ip4, prefix_len}
        else
          _ -> :error
        end
    end
  end

  defp parse_ipv4_address(""), do: :error

  defp parse_ipv4_address(addr_str) do
    case :inet.parse_address(String.to_charlist(String.trim(addr_str))) do
      {:ok, {_a, _b, _c, _d} = ip4} ->
        {:ok, ip4, false}

      {:ok, {0, 0, 0, 0, 0, 0xFFFF, gh, ij}} ->
        {:ok, {gh >>> 8, gh &&& 0xFF, ij >>> 8, ij &&& 0xFF}, true}

      _ ->
        :error
    end
  end

  defp parse_prefix_length(prefix_str, mapped?) do
    case Integer.parse(String.trim(prefix_str)) do
      {len, ""} when not mapped? and len in 0..32 ->
        {:ok, len}

      {len, ""} when mapped? and len in 0..32 ->
        {:ok, len}

      {len, ""} when mapped? and len in 96..128 ->
        {:ok, len - 96}

      _ ->
        :error
    end
  end
end
