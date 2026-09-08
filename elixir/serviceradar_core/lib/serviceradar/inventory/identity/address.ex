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

  @doc """
  True when `candidate` is a strictly better primary address than `current`.

  Ties are NOT improvements: an equally-ranked address must not displace the
  current one, or two addresses of the same class would flap on every update.
  """
  @spec better?(term(), term()) :: boolean()
  def better?(candidate, current), do: rank(candidate) > rank(current)

  @doc """
  Pick the best primary address from `candidates`, or `nil` when none is usable.

  Callers MUST treat `nil` as "keep what you have". Replacing a poor address
  with no address trades a partial answer for none -- and on the deployment that
  motivated this, 8 of the 18 affected devices have no routable address at all.
  """
  @spec best(Enumerable.t()) :: String.t() | nil
  def best(candidates) do
    candidates
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&{rank(&1), &1})
    |> Enum.reject(fn {rank, _value} -> rank == 0 end)
    |> case do
      [] -> nil
      ranked -> ranked |> Enum.max_by(fn {rank, _value} -> rank end) |> elem(1)
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
    case best(candidates) do
      nil -> current
      candidate -> if better?(candidate, current), do: candidate, else: current
    end
  end

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
