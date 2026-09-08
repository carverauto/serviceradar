defmodule ServiceRadarWebNGWeb.NetflowLive.Visualize.FlowContext.LocalAnchor do
  @moduledoc """
  Resolves NetFlow endpoint coordinates from operator-defined local-CIDR map
  anchors (`platform.netflow_local_cidrs`).

  GeoIP has no usable coordinates for private/local endpoints (the enrichment
  cache stores a row with NULL lat/lon), so without an anchor a local source or
  destination islands on the flow maps. Operators define "Local CIDRs" with a
  lat/lon anchor in Settings precisely so those endpoints plot at a physical
  site instead.

  The main dashboard NetFlow map already resolves anchors via a SQL LATERAL join
  (`<<=` inet containment). The Flow Details modal builds its context in Elixir,
  so this module mirrors that behaviour: load the enabled anchors once, then
  match an endpoint IP by **inet containment** (never string prefixing),
  longest-prefix (most specific CIDR) wins, honoring the optional partition
  scope. Precedence matches the main map: an anchor with coordinates takes
  precedence over GeoIP, else GeoIP, else nothing.
  """

  alias ServiceRadar.Observability.NetflowLocalCidr
  alias ServiceRadar.Policies.NetworkAddressPolicy

  require Ash.Query
  require Logger

  @doc """
  Loads enabled local-CIDR anchors for the current scope.

  Returns a list of anchor records (or plain maps in tests). Never raises; on
  any failure it returns `[]` so the modal degrades to GeoIP-only rather than
  crashing.
  """
  def load_anchors(scope) do
    NetflowLocalCidr
    |> Ash.Query.for_read(:list)
    |> Ash.Query.filter(enabled == true)
    |> Ash.read(scope: scope)
    |> extract_results()
  rescue
    error ->
      Logger.debug("Failed to load NetFlow local-CIDR anchors", reason: inspect(error))
      []
  catch
    kind, reason ->
      Logger.debug("Failed to load NetFlow local-CIDR anchors", reason: inspect({kind, reason}))
      []
  end

  @doc """
  Returns the best-matching anchor for `ip` as
  `%{latitude: float, longitude: float, label: String.t() | nil}`, or `nil`.

  Matching uses inet containment (IPv4 and IPv6). The most specific CIDR wins;
  ties break on the most recently updated anchor. Partition is honored: an
  anchor with a nil/blank partition is global, and a nil flow partition matches
  any anchor (so we never island a flow just because its partition is unknown).
  Anchors without coordinates are ignored.
  """
  def resolve(anchors, ip, partition) when is_list(anchors) and is_binary(ip) do
    case parse_ip(ip) do
      {:ok, ip_tuple} ->
        anchors
        |> Enum.filter(fn anchor ->
          has_coords?(anchor) and partition_match?(anchor, partition) and
            anchor_contains?(anchor, ip_tuple)
        end)
        |> Enum.sort_by(&anchor_sort_key/1, :desc)
        |> List.first()
        |> to_anchor_point()

      :error ->
        nil
    end
  end

  def resolve(_anchors, _ip, _partition), do: nil

  # --------------------------------------------------------------------------
  # Internals
  # --------------------------------------------------------------------------

  defp extract_results({:ok, %Ash.Page.Keyset{results: results}}) when is_list(results), do: results
  defp extract_results({:ok, results}) when is_list(results), do: results
  defp extract_results(_), do: []

  defp parse_ip(ip) do
    case :inet.parse_address(String.to_charlist(String.trim(ip))) do
      {:ok, tuple} -> {:ok, tuple}
      {:error, _} -> :error
    end
  end

  defp anchor_contains?(anchor, ip_tuple) do
    case cidr_string(anchor) do
      cidr when is_binary(cidr) and cidr != "" ->
        NetworkAddressPolicy.cidr_contains?(ip_tuple, cidr)

      _ ->
        false
    end
  end

  defp partition_match?(anchor, flow_partition) do
    anchor_partition = normalize_partition(Map.get(anchor, :partition))
    flow_partition = normalize_partition(flow_partition)

    is_nil(anchor_partition) or is_nil(flow_partition) or anchor_partition == flow_partition
  end

  defp has_coords?(anchor) do
    is_number(Map.get(anchor, :latitude)) and is_number(Map.get(anchor, :longitude))
  end

  defp anchor_sort_key(anchor) do
    {masklen(cidr_string(anchor)), updated_at_unix(Map.get(anchor, :updated_at))}
  end

  defp to_anchor_point(nil), do: nil

  defp to_anchor_point(anchor) do
    lat = Map.get(anchor, :latitude)
    lon = Map.get(anchor, :longitude)

    if is_number(lat) and is_number(lon) do
      %{latitude: lat, longitude: lon, label: anchor_label(anchor)}
    end
  end

  defp anchor_label(anchor) do
    [Map.get(anchor, :location_label), Map.get(anchor, :label)]
    |> Enum.map(&normalize_label/1)
    |> Enum.find(& &1)
  end

  defp cidr_string(%{cidr: cidr}) when is_binary(cidr), do: cidr
  defp cidr_string(%{cidr: %Postgrex.INET{} = inet}), do: inet_to_string(inet)
  defp cidr_string(_), do: nil

  defp inet_to_string(%Postgrex.INET{address: address, netmask: netmask}) do
    ip = address |> :inet.ntoa() |> to_string()
    if is_integer(netmask), do: "#{ip}/#{netmask}", else: ip
  end

  defp masklen(cidr) when is_binary(cidr) do
    case String.split(cidr, "/", parts: 2) do
      [_ip, bits] ->
        case Integer.parse(String.trim(bits)) do
          {n, _} -> n
          :error -> 0
        end

      _ ->
        0
    end
  end

  defp masklen(_), do: 0

  defp updated_at_unix(%DateTime{} = dt), do: DateTime.to_unix(dt)
  defp updated_at_unix(_), do: 0

  defp normalize_partition(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_partition(_), do: nil

  defp normalize_label(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_label(_), do: nil
end
