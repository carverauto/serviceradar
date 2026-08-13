defmodule ServiceRadarWebNGWeb.DashboardLive.Data.Mtr do
  @moduledoc false

  defmacro __using__(_opts) do
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
          avg_loss_pct: Float.round(avg_loss, 2),
          avg_latency_ms: Float.round(avg_latency_ms, 1),
          degraded_count: Enum.count(overlays, &(&1.loss_pct > 0 or &1.avg_us > 100_000))
        }
      end

      defp merge_mtr_summaries(%{path_count: count} = timeseries, _overlays) when is_integer(count) and count > 0,
        do: timeseries

      defp merge_mtr_summaries(_timeseries, overlays_summary), do: overlays_summary

      @sobelow_skip ["SQL.Query"]
      defp mtr_timeseries_summary(time_window) do
        if relation_exists?("platform.mtr_traces") and relation_exists?("platform.mtr_hops") do
          sql = """
          WITH selected_traces AS (
            SELECT id
            FROM mtr_traces
            WHERE time >= $1
          ),
          last_hops AS (
            SELECT DISTINCT ON (h.trace_id) h.trace_id, h.avg_us
            FROM mtr_hops h
            INNER JOIN selected_traces st ON st.id = h.trace_id
            WHERE h.addr IS NOT NULL
            ORDER BY h.trace_id, h.hop_number DESC
          ),
          hop_loss AS (
            SELECT h.trace_id, AVG(h.loss_pct)::float AS avg_loss_pct
            FROM mtr_hops h
            INNER JOIN selected_traces st ON st.id = h.trace_id
            GROUP BY h.trace_id
          )
          SELECT
            COUNT(st.id)::bigint,
            COALESCE(AVG(NULLIF(lh.avg_us, 0)), 0)::float / 1000.0,
            COALESCE(AVG(hl.avg_loss_pct), 0)::float,
            COUNT(st.id) FILTER (
              WHERE COALESCE(hl.avg_loss_pct, 0) > 0
                 OR COALESCE(lh.avg_us, 0) > 100000
            )::bigint
          FROM selected_traces st
          LEFT JOIN last_hops lh ON lh.trace_id = st.id
          LEFT JOIN hop_loss hl ON hl.trace_id = st.id
          """

          case ServiceRadarWebNG.Repo.query(sql, [cutoff_for_time_window(time_window)]) do
            {:ok, %{rows: [[path_count, avg_latency_ms, avg_loss_pct, degraded_count]]}} ->
              %{
                path_count: to_int(path_count),
                avg_latency_ms: Float.round(to_float(avg_latency_ms), 1),
                avg_loss_pct: Float.round(to_float(avg_loss_pct), 2),
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
    end
  end
end
