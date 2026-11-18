defmodule ServiceRadar.Inventory.Identity.Address do
  @moduledoc """
  Classifies an IP address by how useful it is as a device's PRIMARY address.

  A device's primary address is what an operator reads, what a link points at,
  and what correlates the device with the rest of inventory. Choosing it by
  arrival order rather than by usefulness is how 25 of 126 live devices on one
  deployment ended up presenting a `fe80::` link-local or a ULA as their address
  (GitHub #3905) -- addresses that are not routable, not unique beyond a link,
  and cannot be used to reach the device.

  The ranking, strongest first:

    global      routable, the address that actually identifies the host
    private     RFC1918 / RFC6598 -- reachable within the deployment
    unique_local  fc00::/7 -- stable but not globally routable
    link_local  fe80::/10, 169.254/16 -- valid only on one link
    loopback / unspecified -- never a primary address

  ULA addresses stay valuable as alias evidence. Link-local does not: it is
  unique per link, not globally, so it must never become a device alias
  (GitHub #4022). It remains valid on interface records.

  `AliasPolicy.valid_alias_ip?/1` is the alias gate and is driven off
  `classify/1`. `rank/1` is only the primary-address preference; a rank of 20
  is not itself the alias veto.

  Parsing goes through `:inet.parse_address/1` rather than string prefixes. A
  prefix test gets `fe80::/10` wrong (the range runs `fe80`..`febf`, so "fe9"
  and "fea" are link-local too), silently accepts malformed input, and cannot
  see that `::ffff:192.168.1.1` is really an IPv4 address.
  """

  import Bitwise

  @type classification ::
          :global | :private | :unique_local | :link_local | :loopback | :unspecified | :invalid

  @ranks %{
    global: 50,
    private: 40,
    unique_local: 30,
    link_local: 20,
    loopback: 0,
    unspecified: 0,
    invalid: 0
  }

  @doc """
  Classify an address string.

  Accepts a zone suffix (`fe80::1%eth0`) and a CIDR suffix (`192.168.1.1/24`),
  because both reach inventory from real collectors.
  """
  @spec classify(term()) :: classification()
  def classify(value) when is_binary(value) do
    value
    |> normalize()
    |> parse()
    |> classify_parsed()
  end

  def classify(_value), do: :invalid

  @doc """
  How preferable this address is as a primary. Higher is better; 0 means
  "never use as primary".
  """
  @spec rank(term()) :: non_neg_integer()
  def rank(value), do: Map.fetch!(@ranks, classify(value))

  @typedoc """
  Fitness class of a primary address, strongest first: a usable IPv4 (routable,
  rank 40 or 50), a routable IPv6 (global or ULA), a link-local of either family,
  and never.
  """
  @type strength_class :: :usable_ipv4 | :routable_ipv6 | :link_local | :never

  @class_weights %{usable_ipv4: 300, routable_ipv6: 200, link_local: 100, never: 0}

  @doc """
  The fitness class of an address as a primary.

  The family decides before the rank: a device that has a usable IPv4 presents it,
  and an IPv6 is the primary only of an IPv6-only device. A `169.254/16` address
  is link-local, not a usable IPv4, so a routable IPv6 outranks it. An
  IPv4-mapped IPv6 (`::ffff:a.b.c.d`) is judged as the IPv4 it carries.
  """
  @spec strength_class(term()) :: strength_class()
  def strength_class(value) do
    case parsed_class(value) do
      {_family, :link_local} -> :link_local
      {_family, class} when class in [:loopback, :unspecified, :invalid] -> :never
      {:ipv4, _class} -> :usable_ipv4
      {:ipv6, _class} -> :routable_ipv6
    end
  end

  @doc """
  The strength of an address as a primary: its class (`strength_class/1`) first,
  then its rank within the class. A stored primary is replaced only by an address
  of strictly greater strength. Mirrors `platform.sr_address_strength(text)`; the
  two are kept in step by a parity test.
  """
  @spec strength(term()) :: non_neg_integer()
  def strength(value) do
    case strength_class(value) do
      :never -> 0
      class -> Map.fetch!(@class_weights, class) + rank(value)
    end
  end

  @doc "True for a routable IPv4 (rank 40 or higher): the address a device presents when it has one."
  @spec usable_ipv4?(term()) :: boolean()
  def usable_ipv4?(value), do: strength_class(value) == :usable_ipv4

  @doc "True for an `fe80::/10` or `169.254/16` address."
  @spec link_local?(term()) :: boolean()
  def link_local?(value), do: strength_class(value) == :link_local

  @doc """
  True when `candidate` is a strictly better primary address than `current`.

  A usable IPv4 beats any IPv6, a routable address of either family beats a
  link-local of either family, and otherwise the higher rank within the family
  wins. Ties are NOT improvements: an equally strong address must not displace the
  current one, or two addresses of the same class would flap on every update.
  """
  @spec better?(term(), term()) :: boolean()
  def better?(candidate, current), do: strength(candidate) > strength(current)

  @doc """
  True when `candidate` is of a weaker class (`strength_class/1`) than `current`: a
  usable IPv4 replaced by an IPv6, a routable address replaced by a link-local. An
  absent primary is replaced by a weaker class only once it has left its recording
  source's sighting window; a same-class re-IP (one usable IPv4 to another) is not a
  downgrade. Mirrors `platform.sr_address_strength(text) / 100`.
  """
  @spec class_downgrade?(term(), term()) :: boolean()
  def class_downgrade?(candidate, current),
    do: div(strength(candidate), 100) < div(strength(current), 100)

  @doc """
  Pick the best primary address from `candidates`, or `nil` when none is usable.

  The strongest candidate wins (`strength/1`). Only among candidates of equal
  strength is the tie broken: `stored`, the device's current primary, first when
  it is among them, then the lowest address. A tie is never broken across
  strengths.

  Callers MUST treat `nil` as "keep what you have". Replacing a poor address
  with no address trades a partial answer for none -- and on the deployment that
  motivated this, 8 of the 18 affected devices have no routable address at all.
  """
  @spec best(Enumerable.t(), term()) :: String.t() | nil
  def best(candidates, stored \\ nil) do
    candidates
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&{strength(&1), &1})
    |> Enum.reject(fn {strength, _value} -> strength == 0 end)
    |> case do
      [] ->
        nil

      ranked ->
        top = ranked |> Enum.map(&elem(&1, 0)) |> Enum.max()

        ranked
        |> Enum.filter(fn {strength, _value} -> strength == top end)
        |> Enum.map(&elem(&1, 1))
        |> Enum.uniq()
        |> tie_break(stored)
    end
  end

  defp tie_break(values, stored) do
    if is_binary(stored) and stored in values,
      do: stored,
      else: Enum.min_by(values, &address_sort_key/1)
  end

  # Lowest address by family, then numeric value; an unparseable string sorts last.
  defp address_sort_key(value) do
    case value |> normalize() |> parse() do
      {_a, _b, _c, _d} = v4 -> {4, Tuple.to_list(v4), value}
      parsed when tuple_size(parsed) == 8 -> {6, Tuple.to_list(parsed), value}
      _ -> {9, [], value}
    end
  end

  @doc """
  The address a device should present, given its current one and everything
  else known about it.

  Returns `current` unless a candidate is strictly better, so this is safe to
  call on every update: it promotes, and never demotes or blanks.
  """
  @spec preferred_primary(term(), Enumerable.t()) :: term()
  def preferred_primary(current, candidates) do
    case best(candidates, current) do
      nil -> current
      candidate -> if better?(candidate, current), do: candidate, else: current
    end
  end

  defp parsed_class(value) when is_binary(value) do
    parsed = value |> normalize() |> parse()
    {family(parsed), classify_parsed(parsed)}
  end

  defp parsed_class(_value), do: {:none, :invalid}

  defp family({_a, _b, _c, _d}), do: :ipv4
  defp family({0, 0, 0, 0, 0, 0xFFFF, _gh, _ij}), do: :ipv4
  defp family({_a, _b, _c, _d, _e, _f, _g, _h}), do: :ipv6
  defp family(_parsed), do: :none

  defp normalize(value) do
    value
    |> String.trim()
    |> String.split("%", parts: 2)
    |> hd()
    |> String.split("/", parts: 2)
    |> hd()
  end

  defp parse(""), do: :error

  defp parse(value) do
    case :inet.parse_address(String.to_charlist(value)) do
      {:ok, parsed} -> parsed
      {:error, _reason} -> :error
    end
  end

  defp classify_parsed(:error), do: :invalid

  # IPv4
  defp classify_parsed({0, 0, 0, 0}), do: :unspecified
  defp classify_parsed({127, _b, _c, _d}), do: :loopback
  defp classify_parsed({169, 254, _c, _d}), do: :link_local
  defp classify_parsed({10, _b, _c, _d}), do: :private
  defp classify_parsed({172, b, _c, _d}) when b >= 16 and b <= 31, do: :private
  defp classify_parsed({192, 168, _c, _d}), do: :private
  # RFC6598 carrier-grade NAT: reachable inside the deployment, never globally.
  defp classify_parsed({100, b, _c, _d}) when b >= 64 and b <= 127, do: :private
  defp classify_parsed({_a, _b, _c, _d}), do: :global

  # IPv6
  defp classify_parsed({0, 0, 0, 0, 0, 0, 0, 0}), do: :unspecified
  defp classify_parsed({0, 0, 0, 0, 0, 0, 0, 1}), do: :loopback

  # IPv4-mapped (::ffff:a.b.c.d) is an IPv4 address wearing an IPv6 shape, and
  # must be judged as one -- otherwise a mapped RFC1918 address reads as global.
  defp classify_parsed({0, 0, 0, 0, 0, 0xFFFF, gh, ij}) do
    classify_parsed({gh >>> 8, gh &&& 0xFF, ij >>> 8, ij &&& 0xFF})
  end

  defp classify_parsed({a, _b, _c, _d, _e, _f, _g, _h}) when (a &&& 0xFFC0) == 0xFE80,
    do: :link_local

  defp classify_parsed({a, _b, _c, _d, _e, _f, _g, _h}) when (a &&& 0xFE00) == 0xFC00,
    do: :unique_local

  defp classify_parsed({_a, _b, _c, _d, _e, _f, _g, _h}), do: :global

  defp classify_parsed(_other), do: :invalid
end
