defmodule ServiceRadarWebNGWeb.LogLive.NetflowPanelQueries do
  @moduledoc """
  The SRQL each NetFlow panel of the observability page sends, built from the page's base
  `in:flows ...` query (its filters and window, already reduced by the page).

  A panel is named for what it computes, and the name fixes everything that decides the
  query's translation: the aggregate, the group or series field, the sort. The caller supplies
  only what does not: the base query, the `:limit`, and a series panel's `:bucket` width.

  `ServiceRadarWebNGWeb.LogLive.Index` builds every panel query through `query/3`, and
  `panels/0` lists every panel, so the set of queries the page can send is enumerable. The
  StarRocks-vs-CNPG parity inventory is checked against it
  (`ServiceRadarWebNGWeb.SRQL.WarehouseQueryInventoryTest`).
  """

  # Ranked panels: {aggregate, group field, sort column}, sorted descending.
  @ranked %{
    bytes_by_src_ip: {"sum(bytes_total) as total_bytes", "src_endpoint_ip", "total_bytes"},
    packets_by_src_ip: {"sum(packets_total) as total_packets", "src_endpoint_ip", "total_packets"},
    bytes_by_dst_port: {"sum(bytes_total) as total_bytes", "dst_endpoint_port", "total_bytes"},
    bytes_by_app: {"sum(bytes_total) as total_bytes", "app", "total_bytes"},
    bytes_by_src_country: {"sum(bytes_total) as total_bytes", "src_country_iso2", "total_bytes"},
    bytes_by_dst_country: {"sum(bytes_total) as total_bytes", "dst_country_iso2", "total_bytes"}
  }

  # Bucketed byte series: the series field, or nil for the one total series.
  @series %{
    bytes_series: nil,
    bytes_by_protocol_group_series: "protocol_group",
    bytes_by_app_series: "app",
    bytes_by_src_ip_series: "src_endpoint_ip",
    bytes_by_dst_port_series: "dst_endpoint_port"
  }

  @type panel :: atom()

  @doc "Every panel, ranked and series."
  @spec panels() :: [panel()]
  def panels, do: Enum.sort(Map.keys(@ranked) ++ Map.keys(@series))

  @doc "The field a panel groups or splits its series by; nil for the total series."
  @spec group_field(panel()) :: String.t() | nil
  def group_field(panel) when is_map_key(@ranked, panel), do: @ranked |> Map.fetch!(panel) |> elem(1)
  def group_field(panel) when is_map_key(@series, panel), do: Map.fetch!(@series, panel)

  @doc """
  The query for `panel` over `base_query`. Every panel takes `:limit`; a series panel also
  takes `:bucket`, the SRQL bucket width.
  """
  @spec query(panel(), String.t(), keyword()) :: String.t()
  def query(panel, base_query, opts) when is_map_key(@ranked, panel) and is_binary(base_query) do
    {aggregate, field, sort} = Map.fetch!(@ranked, panel)
    limit = Keyword.fetch!(opts, :limit)

    ~s|#{base_query} stats:"#{aggregate} by #{field}" sort:#{sort}:desc limit:#{limit}|
  end

  def query(panel, base_query, opts) when is_map_key(@series, panel) and is_binary(base_query) do
    bucket = Keyword.fetch!(opts, :bucket)
    limit = Keyword.fetch!(opts, :limit)

    series =
      case Map.fetch!(@series, panel) do
        nil -> ""
        field -> " series:#{field}"
      end

    "#{base_query} bucket:#{bucket} agg:sum value_field:bytes_total#{series} limit:#{limit}"
  end
end
