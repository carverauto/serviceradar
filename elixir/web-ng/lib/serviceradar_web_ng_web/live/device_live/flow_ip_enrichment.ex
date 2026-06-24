defmodule ServiceRadarWebNGWeb.DeviceLive.FlowIpEnrichment do
  @moduledoc false

  alias Phoenix.Component
  alias ServiceRadar.Observability.IpGeoEnrichmentCache
  alias ServiceRadar.Observability.IpRdnsCache
  alias ServiceRadarWebNGWeb.NetFlow.EnrichmentExpiry

  require Ash.Query

  @default_timeout_ms 3_000

  def enrich_socket(socket, timeout_ms \\ @default_timeout_ms) do
    flows = socket.assigns.device_flows
    scope = Map.get(socket.assigns, :current_scope)
    ips = ips(flows)

    if ips == [] do
      socket |> Component.assign(:rdns_map, %{}) |> Component.assign(:geo_iso2_map, %{})
    else
      tasks = [
        Task.async(fn -> {:rdns, bulk_rdns(ips, scope)} end),
        Task.async(fn -> {:geo, bulk_geo_iso2(ips, scope)} end)
      ]

      results = safe_yield_many(tasks, timeout_ms)

      socket
      |> Component.assign(:rdns_map, Map.get(results, :rdns, %{}))
      |> Component.assign(:geo_iso2_map, Map.get(results, :geo, %{}))
    end
  end

  def load_maps(ips, scope) when is_list(ips) do
    {bulk_rdns(ips, scope), bulk_geo_iso2(ips, scope)}
  end

  def ips(flows) when is_list(flows) do
    flows
    |> Enum.flat_map(fn flow ->
      [Map.get(flow, "src_endpoint_ip"), Map.get(flow, "dst_endpoint_ip")]
    end)
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.take(200)
  end

  def ips(_), do: []

  defp bulk_rdns(ips, scope) do
    now = DateTime.utc_now()

    query =
      IpRdnsCache
      |> Ash.Query.for_read(:read, %{})
      |> EnrichmentExpiry.live_for_ips(ips, now)

    case Ash.read(query, scope: scope) do
      {:ok, rows} when is_list(rows) ->
        rows
        |> Enum.filter(&rdns_row_valid?/1)
        |> Map.new(fn r -> {r.ip, r.hostname} end)

      _ ->
        %{}
    end
  rescue
    _ -> %{}
  end

  defp rdns_row_valid?(r) do
    ok? =
      case r.status do
        :ok -> true
        "ok" -> true
        s when is_binary(s) -> String.downcase(String.trim(s)) == "ok"
        _ -> false
      end

    ok? and is_binary(r.hostname) and String.trim(r.hostname) != ""
  end

  defp bulk_geo_iso2(ips, scope) do
    now = DateTime.utc_now()

    query =
      IpGeoEnrichmentCache
      |> Ash.Query.for_read(:read, %{})
      |> EnrichmentExpiry.live_for_ips(ips, now)

    case Ash.read(query, scope: scope) do
      {:ok, rows} when is_list(rows) ->
        rows
        |> Enum.filter(fn r ->
          is_binary(r.country_iso2) and String.length(String.trim(r.country_iso2)) == 2
        end)
        |> Map.new(fn r -> {r.ip, String.upcase(String.trim(r.country_iso2))} end)

      _ ->
        %{}
    end
  rescue
    _ -> %{}
  end

  defp safe_yield_many(tasks, timeout_ms) do
    tasks
    |> Task.yield_many(timeout_ms)
    |> Enum.reduce(%{}, fn
      {_task, {:ok, {key, value}}}, acc when is_atom(key) ->
        Map.put(acc, key, value)

      {task, _result}, acc ->
        Task.shutdown(task, :brutal_kill)
        acc
    end)
  end
end
