defmodule ServiceRadarWebNGWeb.DashboardLive.Data.Mtr do
  @moduledoc false

  defmacro __using__(_opts) do
    quote do
      unquote(overlay_definitions())
      unquote(timeseries_definitions())
    end
  end

  defp overlay_definitions do
    quote do
      defp mtr_overlays do
        if mtr_path_edges_present?() do
          cypher = """
          MATCH (a)-[r:MTR_PATH]->(b)
          WHERE a.id IS NOT NULL AND b.id IS NOT NULL
          RETURN {
            source: a.id,
            target: b.id,
            source_addr: coalesce(a.addr, ''),
            target_addr: coalesce(b.addr, ''),
            avg_us: coalesce(r.avg_us, 0),
            loss_pct: coalesce(r.loss_pct, 0.0),
            jitter_us: coalesce(r.jitter_us, 0),
            from_hop: coalesce(r.from_hop, 0),
            to_hop: coalesce(r.to_hop, 0),
            agent_id: coalesce(r.agent_id, '')
          }
          LIMIT #{80}
          """

          case ServiceRadarWebNG.Graph.query(cypher) do
            {:ok, rows} when is_list(rows) ->
              rows
              |> Enum.map(&normalize_mtr_overlay/1)
              |> Enum.reject(&is_nil/1)

            _ ->
              []
          end
        else
          []
        end
      rescue
        _ -> []
      end

      defp mtr_path_edges_present? do
        case ServiceRadarWebNG.Graph.query("MATCH ()-[r:MTR_PATH]->() RETURN count(r)") do
          {:ok, [%{"count" => count}]} -> to_int(count) > 0
          {:ok, [%{count: count}]} -> to_int(count) > 0
          {:ok, [count]} -> to_int(count) > 0
          _ -> false
        end
      rescue
        _ -> false
      end

      defp normalize_mtr_overlay(%{} = row) do
        row = unwrap_single_map(row)
        source = map_value(row, "source")
        target = map_value(row, "target")

        if present?(source) and present?(target) do
          loss_pct = to_float(map_value(row, "loss_pct"))
          avg_us = to_int(map_value(row, "avg_us"))

          %{
            id: "mtr-#{source}-#{target}",
            from: point_for(map_value(row, "source_addr") || source),
            to: point_for(map_value(row, "target_addr") || target),
            source_label: source,
            target_label: target,
            source_addr: map_value(row, "source_addr") || "",
            target_addr: map_value(row, "target_addr") || "",
            avg_us: avg_us,
            loss_pct: loss_pct,
            jitter_us: to_int(map_value(row, "jitter_us")),
            magnitude: max(avg_us, 1),
            color: mtr_color(loss_pct, avg_us)
          }
        end
      end

      defp normalize_mtr_overlay(_), do: nil

      defp summarize_mtr_overlays([]), do: empty_mtr_summary()

      defp summarize_mtr_overlays(overlays) do
        count = length(overlays)
        avg_loss = overlays |> Enum.map(& &1.loss_pct) |> average()
        avg_latency_ms = overlays |> Enum.map(fn overlay -> overlay.avg_us / 1000 end) |> average()

        %{
          path_count: count,
          endpoint_sample_count: 0,
          loss_sample_count: 0,
          latency_sample_count: 0,
          avg_loss_pct: Float.round(avg_loss, 2),
          avg_latency_ms: Float.round(avg_latency_ms, 1),
          degraded_count: Enum.count(overlays, &(&1.loss_pct > 0 or &1.avg_us > 100_000))
        }
      end

      defp merge_mtr_summaries(%{path_count: count} = timeseries, _overlays) when is_integer(count) and count > 0,
        do: timeseries

      defp merge_mtr_summaries(_timeseries, overlays_summary), do: overlays_summary
    end
  end

  defp timeseries_definitions do
    quote do
      @sobelow_skip ["SQL.Query"]
      defp mtr_timeseries_summary(time_window) do
        if relation_exists?("platform.mtr_traces") and relation_exists?("platform.mtr_hops") do
          sql = """
          WITH selected_traces AS (
            SELECT id, target_reached, total_hops
            FROM mtr_traces
            WHERE time >= $1
          ),
          destination_hops AS (
            SELECT trace_id, sent, received, avg_us
            FROM (
              SELECT
                h.trace_id,
                h.sent,
                h.received,
                h.avg_us,
                ROW_NUMBER() OVER (
                  PARTITION BY h.trace_id
                  ORDER BY h.time DESC, h.id DESC
                ) AS terminal_rank
              FROM mtr_hops h
              INNER JOIN selected_traces st ON st.id = h.trace_id
                AND st.target_reached
                AND h.hop_number = st.total_hops
            ) terminal_candidates
            WHERE terminal_rank = 1
          )
          SELECT
            COUNT(st.id)::bigint,
            COUNT(dh.trace_id)::bigint,
            COUNT(dh.trace_id) FILTER (WHERE dh.sent > 0)::bigint,
            COUNT(dh.trace_id) FILTER (WHERE dh.avg_us IS NOT NULL AND dh.received > 0)::bigint,
            (
              100.0 * (
                SUM(dh.sent::numeric) FILTER (WHERE dh.sent > 0) -
                  SUM(dh.received::numeric) FILTER (WHERE dh.sent > 0)
              ) /
                NULLIF(SUM(dh.sent::numeric) FILTER (WHERE dh.sent > 0), 0)
            )::float8,
            (
              SUM(dh.avg_us::numeric * dh.received::numeric)
                FILTER (WHERE dh.avg_us IS NOT NULL AND dh.received > 0) /
                NULLIF(
                  SUM(dh.received::numeric)
                    FILTER (WHERE dh.avg_us IS NOT NULL AND dh.received > 0),
                  0
                ) /
                1000.0
            )::float8,
            COUNT(st.id) FILTER (
              WHERE NOT st.target_reached
                 OR (dh.sent > dh.received)
                 OR (dh.avg_us IS NOT NULL AND dh.received > 0 AND dh.avg_us > 100000)
            )::bigint
          FROM selected_traces st
          LEFT JOIN destination_hops dh ON dh.trace_id = st.id
          """

          case ServiceRadarWebNG.Repo.query(sql, [cutoff_for_time_window(time_window)]) do
            {:ok,
             %{
               rows: [
                 [
                   path_count,
                   endpoint_sample_count,
                   loss_sample_count,
                   latency_sample_count,
                   avg_loss_pct,
                   avg_latency_ms,
                   degraded_count
                 ]
               ]
             }} ->
              %{
                path_count: to_int(path_count),
                endpoint_sample_count: to_int(endpoint_sample_count),
                loss_sample_count: to_int(loss_sample_count),
                latency_sample_count: to_int(latency_sample_count),
                avg_latency_ms: round_nullable(avg_latency_ms, 1),
                avg_loss_pct: round_nullable(avg_loss_pct, 2),
                degraded_count: to_int(degraded_count)
              }

            _ ->
              empty_mtr_summary()
          end
        else
          empty_mtr_summary()
        end
      rescue
        _ -> empty_mtr_summary()
      end

      defp round_nullable(nil, _precision), do: nil
      defp round_nullable(value, precision), do: Float.round(to_float(value), precision)
    end
  end
end
