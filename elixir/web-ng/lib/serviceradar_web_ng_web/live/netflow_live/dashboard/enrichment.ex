defmodule ServiceRadarWebNGWeb.NetflowLive.Dashboard.Enrichment do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]
  import ServiceRadarWebNGWeb.NetflowLive.Dashboard.Helpers

  alias ServiceRadar.Observability.IpGeoEnrichmentCache
  alias ServiceRadar.Observability.IpRdnsCache
  alias ServiceRadarWebNGWeb.NetFlow.EnrichmentExpiry

  require Ash.Query

  # ---------------------------------------------------------------------------
  # IP enrichment (reads from pre-populated DB caches, no live lookups)
  # ---------------------------------------------------------------------------

  def enrich_top_n_ips(socket) do
    scope = Map.get(socket.assigns, :current_scope)

    ips =
      [
        Enum.map(socket.assigns.top_talkers, & &1.ip),
        Enum.map(socket.assigns.top_listeners, & &1.ip),
        Enum.flat_map(socket.assigns.top_conversations, fn r -> [r.src_ip, r.dst_ip] end)
      ]
      |> Enum.concat()
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    if ips == [] do
      socket
      |> assign(:rdns_map, %{})
      |> assign(:geo_iso2_map, %{})
    else
      tasks = [
        Task.async(fn -> {:rdns, bulk_rdns(ips, scope)} end),
        Task.async(fn -> {:geo, bulk_geo_iso2(ips, scope)} end)
      ]

      results = safe_await_many(tasks, to_timeout(second: 5))

      socket
      |> assign(:rdns_map, Map.get(results, :rdns, %{}))
      |> assign(:geo_iso2_map, Map.get(results, :geo, %{}))
    end
  end

  defp bulk_rdns(ips, scope) do
    now = DateTime.utc_now()

    query =
      IpRdnsCache
      |> Ash.Query.for_read(:read, %{})
      |> EnrichmentExpiry.live_for_ips(ips, now)

    case Ash.read(query, scope: scope) do
      {:ok, rows} ->
        rows = ash_results(rows)

        rows
        |> Enum.filter(fn r ->
          r.status == "ok" and is_binary(r.hostname) and String.trim(r.hostname) != ""
        end)
        |> Map.new(fn r -> {r.ip, r.hostname} end)

      _ ->
        %{}
    end
  end

  defp bulk_geo_iso2(ips, scope) do
    now = DateTime.utc_now()

    query =
      IpGeoEnrichmentCache
      |> Ash.Query.for_read(:read, %{})
      |> EnrichmentExpiry.live_for_ips(ips, now)

    case Ash.read(query, scope: scope) do
      {:ok, rows} ->
        rows = ash_results(rows)

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
end
