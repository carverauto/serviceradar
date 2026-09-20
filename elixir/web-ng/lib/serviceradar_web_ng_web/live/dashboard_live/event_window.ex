defmodule ServiceRadarWebNGWeb.DashboardLive.EventWindow do
  @moduledoc false

  alias ServiceRadar.Analytics.StarRocks.LogEventConsumers
  alias ServiceRadarWebNGWeb.DashboardLive.Window

  def load(window, opts \\ []) do
    bucket_seconds = Window.event_bucket_seconds(window)
    query = Keyword.get(opts, :query, &ServiceRadarWebNG.Repo.query/2)

    with {:ok, %{rows: rows}} <- fetch_rows(window, bucket_seconds, query, opts) do
      {:ok, build_slice(window, bucket_seconds, rows)}
    end
  end

  defp fetch_rows(window, bucket_seconds, query, opts) do
    LogEventConsumers.fetch(:events,
      cnpg: fn ->
        query.(sql(bucket_seconds >= 3_600), [window.start, window.end, bucket_seconds])
      end,
      starrocks: fn ->
        starrocks_opts =
          case Keyword.get(opts, :starrocks_query) do
            fun when is_function(fun, 1) -> [query: fun]
            _ -> []
          end

        LogEventConsumers.event_window_rows(
          window.start,
          window.end,
          bucket_seconds,
          starrocks_opts
        )
      end
    )
  end

  def sql(use_rollup?) do
    source =
      if use_rollup? do
        """
        WITH bounds AS NOT MATERIALIZED (
          SELECT GREATEST(
            date_trunc('hour', $1::timestamptz, 'UTC') +
              CASE WHEN $1::timestamptz = date_trunc('hour', $1::timestamptz, 'UTC') THEN INTERVAL '0' ELSE INTERVAL '1 hour' END,
            COALESCE((SELECT MIN(bucket) FROM platform.ocsf_events_hourly_stats), $2::timestamptz)
          ) AS rollup_start,
          LEAST(date_trunc('hour', $2::timestamptz, 'UTC'),
            COALESCE((SELECT MAX(bucket) + INTERVAL '1 hour' FROM platform.ocsf_events_hourly_stats), $1::timestamptz)
          ) AS rollup_end
        ), source AS (
          SELECT bucket AS time, severity_id, total_count
          FROM platform.ocsf_events_hourly_stats CROSS JOIN bounds
          WHERE bucket >= rollup_start AND bucket < rollup_end
          UNION ALL
          SELECT time, COALESCE(severity_id, 0), 1::bigint
          FROM platform.ocsf_events CROSS JOIN bounds
          WHERE time >= $1 AND time < $2
            AND (rollup_start >= rollup_end OR time < rollup_start OR time >= rollup_end)
        )
        """
      else
        """
        WITH source AS (
          SELECT time, COALESCE(severity_id, 0) AS severity_id, 1::bigint AS total_count
          FROM platform.ocsf_events WHERE time >= $1 AND time < $2
        )
        """
      end

    source <>
      """
      SELECT time_bucket(make_interval(secs => $3::int), time), severity_id, SUM(total_count)::bigint
      FROM source GROUP BY 1, 2 ORDER BY 1, 2
      """
  end

  defp build_slice(window, bucket_seconds, rows) do
    by_bucket = Enum.group_by(rows, fn [bucket, _, _] -> DateTime.to_unix(bucket) end)
    first = div(DateTime.to_unix(window.start), bucket_seconds) * bucket_seconds
    last = DateTime.to_unix(window.end) - 1
    buckets = first..last//bucket_seconds

    points =
      for unix <- buckets do
        bucket = DateTime.from_unix!(unix)

        Enum.reduce(
          Map.get(by_bucket, unix, []),
          %{
            bucket: bucket,
            range_start: latest(bucket, window.start),
            bucket_end: earliest(DateTime.add(bucket, bucket_seconds, :second), window.end),
            total: 0,
            low: 0,
            medium: 0,
            high: 0,
            critical: 0
          },
          fn [_, severity, count], point ->
            point = Map.update!(point, :total, &(&1 + count))

            case severity do
              value when value in [1, 2] -> Map.update!(point, :low, &(&1 + count))
              3 -> Map.update!(point, :medium, &(&1 + count))
              4 -> Map.update!(point, :high, &(&1 + count))
              value when is_integer(value) and value >= 5 -> Map.update!(point, :critical, &(&1 + count))
              _ -> point
            end
          end
        )
      end

    scored = Enum.flat_map(buckets, &Map.get(by_bucket, &1, []))

    summary =
      Enum.reduce(scored, ServiceRadarWebNGWeb.Stats.empty_events_summary(), fn [_, severity, count], acc ->
        field =
          %{0 => :unknown, 1 => :informational, 2 => :low, 3 => :medium, 4 => :high, 5 => :critical, 6 => :fatal}[
            severity
          ] || :unknown

        acc |> Map.update!(:total, &(&1 + count)) |> Map.update(field, count, &(&1 + count))
      end)

    %{events_window: window.value, security_trend: points, event_summary: summary}
  end

  defp latest(a, b), do: if(DateTime.before?(a, b), do: b, else: a)
  defp earliest(a, b), do: if(DateTime.after?(a, b), do: b, else: a)
end
