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
    end
  end
end
