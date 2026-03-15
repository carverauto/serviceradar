defmodule ServiceRadar.NetworkDiscovery.RouteAnalyzer do
  @moduledoc """
  Deterministic route-path analyzer for mapper route snapshots.

  Input is a `routes_by_device` map where each device key maps to a list of
  route entries:

      %{
        "sr:router-a" => [
          %{prefix: "10.10.0.0/16", next_hops: [%{target_device_id: "sr:router-b"}]},
          %{prefix: "0.0.0.0/0", next_hops: [%{target_device_id: "sr:internet"}]}
        ]
      }

  The analyzer applies longest-prefix-match, recursively follows next hops,
  emits ECMP branches, and detects loops/blackholes.
  """

  import Bitwise

  @default_max_hops 16

  @type hop :: %{
          device_id: String.t(),
          selected_prefix: String.t(),
          prefix_length: non_neg_integer(),
          ecmp_branches: [map()]
        }

  @type result :: %{
          status: :delivered | :blackhole | :loop | :max_hops,
          destination_ip: String.t(),
          start_device_id: String.t(),
          hops: [hop()],
          terminal_device_id: String.t() | nil,
          reason: String.t()
        }

  @spec analyze(map(), String.t(), String.t(), keyword()) :: {:ok, result()} | {:error, term()}
  def analyze(routes_by_device, start_device_id, destination_ip, opts \\ [])

  def analyze(routes_by_device, start_device_id, destination_ip, opts)
      when is_map(routes_by_device) and is_binary(start_device_id) and is_binary(destination_ip) do
    max_hops = Keyword.get(opts, :max_hops, @default_max_hops)

    with {:ok, destination_int} <- parse_ipv4(destination_ip) do
      state = %{
        routes_by_device: routes_by_device,
        destination_ip: destination_ip,
        destination_int: destination_int,
        max_hops: if(is_integer(max_hops) and max_hops > 0, do: max_hops, else: @default_max_hops)
      }

      {:ok, walk(state, start_device_id, MapSet.new(), [], 0)}
    end
  end

  def analyze(_, _, _, _), do: {:error, :invalid_arguments}

  defp walk(state, device_id, visited, hops, depth) do
    cond do
      depth >= state.max_hops ->
        route_result(state, :max_hops, device_id, hops, "maximum_hops_exceeded")

      MapSet.member?(visited, device_id) ->
        route_result(state, :loop, device_id, hops, "loop_detected")

      true ->
        resolve_route(state, device_id, visited, hops, depth)
    end
  end

  defp resolve_route(state, device_id, visited, hops, depth) do
    case longest_prefix_match(Map.get(state.routes_by_device, device_id, []), state.destination_int) do
      nil ->
        route_result(state, :blackhole, device_id, hops, "no_matching_route")

      match ->
        continue_from_match(state, device_id, visited, hops, depth, match)
    end
  end

  defp continue_from_match(state, device_id, visited, hops, depth, match) do
    hop = build_hop(device_id, match)
    hop_path = [hop | hops]

    case next_device_from_branches(hop.ecmp_branches) do
      :connected ->
        route_result(state, :delivered, device_id, hop_path, "connected_or_terminal_route")

      {:ok, next_device} ->
        walk(state, next_device, MapSet.put(visited, device_id), hop_path, depth + 1)

      :missing_target ->
        route_result(state, :blackhole, device_id, hop_path, "next_hop_without_target_device")
    end
  end

  defp build_hop(device_id, %{prefix: prefix, prefix_length: prefix_length} = match) do
    %{
      device_id: device_id,
      selected_prefix: prefix,
      prefix_length: prefix_length,
      ecmp_branches: normalize_next_hops(match)
    }
  end

  defp next_device_from_branches([]), do: :connected

  defp next_device_from_branches(branches) do
    case branches |> Enum.sort_by(&branch_sort_key/1) |> List.first() |> Map.get(:target_device_id) do
      next_device when is_binary(next_device) ->
        if String.trim(next_device) == "" do
          :missing_target
        else
          {:ok, next_device}
        end

      _ ->
        :missing_target
    end
  end

  defp branch_sort_key(branch) do
    {
      Map.get(branch, :target_device_id) || Map.get(branch, "target_device_id") || "",
      Map.get(branch, :next_hop_ip) || Map.get(branch, "next_hop_ip") || ""
    }
  end

  defp route_result(state, status, device_id, hops, reason) do
    %{
      status: status,
      destination_ip: state.destination_ip,
      start_device_id: first_hop_device(hops, device_id),
      hops: Enum.reverse(hops),
      terminal_device_id: device_id,
      reason: reason
    }
  end

  defp first_hop_device([last | _], _fallback), do: Map.get(last, :device_id)
  defp first_hop_device([], fallback), do: fallback

  defp longest_prefix_match(routes, destination_int) when is_list(routes) do
    routes
    |> Enum.map(&normalize_route_entry/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.filter(&route_matches_destination?(&1, destination_int))
    |> Enum.max_by(& &1.prefix_length, fn -> nil end)
  end

  defp normalize_route_entry(route) when is_map(route) do
    prefix = Map.get(route, :prefix) || Map.get(route, "prefix")

    with {:ok, network_int, prefix_length} <- parse_cidr(prefix) do
      %{
        prefix: prefix,
        prefix_length: prefix_length,
        network_int: network_int,
        next_hops: Map.get(route, :next_hops) || Map.get(route, "next_hops") || []
      }
    else
      _ -> nil
    end
  end

  defp normalize_route_entry(_), do: nil

  defp route_matches_destination?(route, destination_int) do
    mask = prefix_mask(route.prefix_length)
    (destination_int &&& mask) == route.network_int
  end

  defp normalize_next_hops(route) do
    route.next_hops
    |> List.wrap()
    |> Enum.map(fn hop ->
      %{
        target_device_id: Map.get(hop, :target_device_id) || Map.get(hop, "target_device_id"),
        next_hop_ip: Map.get(hop, :next_hop_ip) || Map.get(hop, "next_hop_ip"),
        interface: Map.get(hop, :interface) || Map.get(hop, "interface")
      }
    end)
    |> Enum.filter(fn hop ->
      target = Map.get(hop, :target_device_id)
      ip = Map.get(hop, :next_hop_ip)

      (is_binary(target) and String.trim(target) != "") or
        (is_binary(ip) and String.trim(ip) != "")
    end)
  end

  defp parse_cidr(value) when is_binary(value) do
    case String.split(String.trim(value), "/", parts: 2) do
      [ip, prefix_len] ->
        with {:ok, ip_int} <- parse_ipv4(ip),
             {len, ""} <- Integer.parse(prefix_len),
             true <- len >= 0 and len <= 32 do
          mask = prefix_mask(len)
          {:ok, ip_int &&& mask, len}
        else
          _ -> {:error, :invalid_cidr}
        end

      _ ->
        {:error, :invalid_cidr}
    end
  end

  defp parse_cidr(_), do: {:error, :invalid_cidr}

  defp parse_ipv4(value) when is_binary(value) do
    with {:ok, {a, b, c, d}} <- :inet.parse_address(String.to_charlist(String.trim(value))) do
      {:ok, (a <<< 24) + (b <<< 16) + (c <<< 8) + d}
    else
      _ -> {:error, :invalid_ipv4}
    end
  end

  defp parse_ipv4(_), do: {:error, :invalid_ipv4}

  defp prefix_mask(0), do: 0
  defp prefix_mask(len), do: ((1 <<< len) - 1) <<< (32 - len)
end
