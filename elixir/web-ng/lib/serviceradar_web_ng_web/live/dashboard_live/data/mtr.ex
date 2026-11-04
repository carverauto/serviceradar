defmodule ServiceRadarWebNGWeb.DashboardLive.Data.Mtr do
  @moduledoc false

  alias ServiceRadarWebNGWeb.DiagnosticsLive.MtrWarehouse

  @doc """
  The MTR card's summary row from the warehouse, or `:cnpg` when StarRocks is
  not enabled and the caller should run its CNPG query instead.

  Exactly one backend is active: with the warehouse enabled the CNPG MTR
  hypertables receive no rows, so the card never falls back to them. It lives
  outside the `__using__` block so that block stays a list of loaders.
  """
  @spec warehouse_summary_rows(DateTime.t(), keyword()) :: {:ok, map()} | {:error, term()} | :cnpg
  def warehouse_summary_rows(cutoff, opts \\ []) do
    if MtrWarehouse.enabled?() do
      MtrWarehouse.dashboard_summary(cutoff, opts)
    else
      :cnpg
    end
  end

  defmacro __using__(_opts) do
    quote do
      unquote(overlay_definitions())
      unquote(timeseries_definitions())
    end
  end

  defp overlay_definitions do
    quote do
      # Most recent MTR path edges from the Dgraph topology graph. A failed
      # read is :unavailable, so the map can say so instead of drawing none.
      defp mtr_overlays do
        case ServiceRadar.Dgraph.query_mtr_paths(80) do
          {:ok, paths} ->
            {:ok, paths |> Enum.map(&normalize_mtr_overlay/1) |> Enum.reject(&is_nil/1)}

          {:error, reason} ->
            require Logger

            Logger.warning("Dashboard MTR overlay read failed: #{inspect(reason)}")
            :unavailable
        end
      end

      defp mtr_overlay_result({:ok, overlays}) when is_list(overlays), do: {overlays, nil}

      defp mtr_overlay_result(_unavailable),
        do: {[], "MTR path overlays are unavailable: the topology graph could not be read."}

      defp normalize_mtr_overlay(%{source: source, target: target} = path)
           when is_binary(source) and source != "" and is_binary(target) and target != "" do
        %{
          id: "mtr-#{source}-#{target}",
          from: point_for(non_empty(path.source_addr) || source),
          to: point_for(non_empty(path.target_addr) || target),
          source_label: source,
          target_label: target,
          source_addr: path.source_addr,
          target_addr: path.target_addr,
          avg_us: path.avg_us,
          loss_pct: path.loss_pct,
          jitter_us: path.jitter_us,
          magnitude: max(path.avg_us, 1),
          color: mtr_color(path.loss_pct, path.avg_us)
        }
      end

      defp normalize_mtr_overlay(_), do: nil

      defp non_empty(""), do: nil
      defp non_empty(value), do: value

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
      defp mtr_timeseries_summary(time_window) do
        cutoff = cutoff_for_time_window(time_window)

        result =
          case unquote(__MODULE__).warehouse_summary_rows(cutoff) do
            :cnpg -> cnpg_mtr_summary_rows(cutoff)
            warehouse -> warehouse
          end

        case result do
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
      rescue
        _ -> empty_mtr_summary()
      end

      @sobelow_skip ["SQL.Query"]
      defp cnpg_mtr_summary_rows(cutoff) do
        if relation_exists?("platform.mtr_traces") and relation_exists?("platform.mtr_hops") do
          sql = """
          WITH selected_traces AS (
            SELECT id, time, target_reached, total_hops
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
                AND h.time >= st.time
              WHERE h.time >= $1
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

          ServiceRadarWebNG.Repo.query(sql, [cutoff])
        else
          :unavailable
        end
      end

      defp round_nullable(nil, _precision), do: nil
      defp round_nullable(value, precision), do: Float.round(to_float(value), precision)
    end
  end
end
