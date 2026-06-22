defmodule ServiceRadarWebNGWeb.NetflowLive.Dashboard.InterfaceSeries do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]
  import ServiceRadarWebNGWeb.NetflowLive.Dashboard.Helpers

  alias ServiceRadarWebNGWeb.NetflowLive.InterfaceTraffic

  def load_interface_timeseries(socket, key) do
    tw = socket.assigns.time_window
    um = socket.assigns.unit_mode
    scope = Map.get(socket.assigns, :current_scope)
    srql_mod = srql_module()
    bucket = timeseries_bucket(tw)
    bucket_secs = bucket_seconds(bucket)
    base = base_flow_query(socket.assigns.query, tw)

    case InterfaceTraffic.find_interface(socket.assigns.top_interfaces, key) do
      %{} = iface ->
        value_field = if(um == "pps", do: "packets_total", else: "bytes_total")

        tasks = [
          Task.async(fn ->
            {:ingress,
             load_iface_downsample(
               srql_mod,
               scope,
               InterfaceTraffic.timeseries_query(base, iface, :ingress, bucket, value_field)
             )}
          end),
          Task.async(fn ->
            {:egress,
             load_iface_downsample(
               srql_mod,
               scope,
               InterfaceTraffic.timeseries_query(base, iface, :egress, bucket, value_field)
             )}
          end)
        ]

        results = safe_await_many(tasks, to_timeout(second: 10))
        ingress = Map.get(results, :ingress, [])
        egress = Map.get(results, :egress, [])

        # Convert per-bucket sums to per-second rates. For "bps" mode, also
        # multiply bytes by 8 so nfFormatRateValue receives bits/sec.
        rate_factor = if(um == "bps", do: 8, else: 1) / max(bucket_secs, 1)

        to_rate = fn v -> Float.round(v * rate_factor, 2) end

        # Merge into stacked-area chart format using the union of ingress/egress timestamps.
        ingress_map = Map.new(ingress, fn %{t: t, v: v} -> {t, to_rate.(v)} end)
        egress_map = Map.new(egress, fn %{t: t, v: v} -> {t, to_rate.(v)} end)

        points =
          ingress_map
          |> Map.keys()
          |> Enum.concat(Map.keys(egress_map))
          |> Enum.uniq()
          |> Enum.sort()
          |> Enum.map(fn t ->
            %{
              "t" => t,
              "ingress" => Map.get(ingress_map, t, 0),
              "egress" => Map.get(egress_map, t, 0)
            }
          end)
          |> Jason.encode!()

        keys = Jason.encode!(["ingress", "egress"])

        socket
        |> assign(:iface_chart_keys_json, keys)
        |> assign(:iface_chart_points_json, points)

      _ ->
        socket
        |> assign(:selected_interface, nil)
        |> assign(:iface_chart_keys_json, "[]")
        |> assign(:iface_chart_points_json, "[]")
    end
  end

  defp load_iface_downsample(srql_mod, scope, query) do
    case srql_mod.query(query, %{scope: scope}) do
      {:ok, %{"results" => results}} when is_list(results) ->
        Enum.map(results, fn row ->
          %{
            t: row["timestamp"] || row["bucket"] || row["time_bucket"],
            v: to_number(row["value"] || row["bytes_total"] || row["packets_total"] || 0)
          }
        end)

      _ ->
        []
    end
  end

  def load_top_interfaces(srql_mod, scope, base, tw) do
    queries = InterfaceTraffic.top_interface_queries(base)

    tasks = [
      Task.async(fn -> {:ingress, srql_results(srql_mod, queries.ingress, scope)} end),
      Task.async(fn -> {:egress, srql_results(srql_mod, queries.egress, scope)} end)
    ]

    results = safe_await_many(tasks, to_timeout(second: 10))

    results
    |> Map.get(:ingress, [])
    |> InterfaceTraffic.project_top_interfaces(Map.get(results, :egress, []))
    |> Enum.map(&load_interface_p95(srql_mod, scope, base, tw, &1))
  end

  # §26.3: p95 is aligned to the selected time window (and the user's filters
  # via `base`), with a per-window bucket (timeseries_bucket/1 yields >=20
  # buckets for every window, so the percentile is always meaningful) and a
  # matching bytes->bps divisor. Previously this hardcoded last_30d / bucket:1h
  # / /3600 — ignoring the selected window, user filters, and yielding a
  # single-bucket (meaningless) p95 for short windows.
  defp load_interface_p95(srql_mod, scope, base, tw, iface) do
    bucket = timeseries_bucket(tw)
    bucket_secs = bucket_seconds(bucket)

    ingress =
      srql_results(
        srql_mod,
        InterfaceTraffic.timeseries_query(base, iface, :ingress, bucket, "bytes_total"),
        scope
      )

    egress =
      srql_results(
        srql_mod,
        InterfaceTraffic.timeseries_query(base, iface, :egress, bucket, "bytes_total"),
        scope
      )

    InterfaceTraffic.with_p95(iface, ingress, egress, bucket_secs)
  end
end
