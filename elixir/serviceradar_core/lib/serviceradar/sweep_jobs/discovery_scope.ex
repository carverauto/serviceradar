defmodule ServiceRadar.SweepJobs.DiscoveryScope do
  @moduledoc """
  Which answering hosts a sweep group may add to inventory as new devices.

  A group discovers new devices only inside its static targets, and only while
  its `discover_new_devices` flag is on. Its target query selects hosts that
  were devices when the agent config compiled, so a host from the query with no
  live device at its address was deleted or moved since; seeding a new device
  there would bring back a bare copy of something an operator or a source
  removed.

  Static targets are read in the forms the sweep group form accepts: single
  IPs, CIDRs and `first-last` ranges, IPv4 or IPv6. An entry that does not
  parse covers nothing.
  """

  import Bitwise

  alias ServiceRadar.Policies.NetworkAddressPolicy
  alias ServiceRadar.SweepJobs.SweepGroup

  @typedoc "Why an answering host was not added to inventory."
  @type skip_reason :: :discovery_off | :outside_static_targets

  @doc """
  Splits `ips` into the hosts `group` may seed as new devices and the rest,
  with the reason the rest are skipped. Unparseable IPs are never seedable.
  """
  @spec partition(SweepGroup.t() | nil, [String.t()]) ::
          {seedable :: [String.t()], skipped :: [String.t()], skip_reason()}
  def partition(%SweepGroup{discover_new_devices: false}, ips), do: {[], ips, :discovery_off}

  def partition(%SweepGroup{static_targets: [_ | _] = targets}, ips) do
    scopes = Enum.flat_map(targets, &parse_target/1)
    {seedable, skipped} = Enum.split_with(ips, &covered?(&1, scopes))
    {seedable, skipped, :outside_static_targets}
  end

  def partition(_group, ips), do: {[], ips, :outside_static_targets}

  defp covered?(ip, scopes) do
    case parse_ip(ip) do
      {:ok, address} -> Enum.any?(scopes, &in_scope?(address, &1))
      :error -> false
    end
  end

  defp in_scope?(address, {:cidr, cidr}), do: NetworkAddressPolicy.cidr_contains?(address, cidr)

  defp in_scope?(address, {:range, first, last}) do
    same_family?(address, first) and to_int(first) <= to_int(address) and
      to_int(address) <= to_int(last)
  end

  defp in_scope?(address, {:ip, target}), do: address == target

  defp parse_target(target) when is_binary(target) do
    target = String.trim(target)

    cond do
      String.contains?(target, "/") -> [{:cidr, target}]
      String.contains?(target, "-") -> parse_range(target)
      true -> parse_single(target)
    end
  end

  defp parse_target(_target), do: []

  defp parse_range(target) do
    with [first_text, last_text] <- String.split(target, "-", parts: 2),
         {:ok, first} <- parse_ip(first_text),
         {:ok, last} <- parse_ip(last_text),
         true <- same_family?(first, last) and to_int(first) <= to_int(last) do
      [{:range, first, last}]
    else
      _ -> []
    end
  end

  defp parse_single(target) do
    case parse_ip(target) do
      {:ok, address} -> [{:ip, address}]
      :error -> []
    end
  end

  defp parse_ip(text) when is_binary(text) do
    case text |> String.trim() |> String.to_charlist() |> :inet.parse_strict_address() do
      {:ok, address} -> {:ok, address}
      {:error, _reason} -> :error
    end
  end

  defp parse_ip(_text), do: :error

  defp same_family?(a, b), do: tuple_size(a) == tuple_size(b)

  defp to_int({a, b, c, d}), do: (a <<< 24) + (b <<< 16) + (c <<< 8) + d

  defp to_int(address) when tuple_size(address) == 8 do
    address |> Tuple.to_list() |> Enum.reduce(0, fn part, acc -> (acc <<< 16) + part end)
  end
end
