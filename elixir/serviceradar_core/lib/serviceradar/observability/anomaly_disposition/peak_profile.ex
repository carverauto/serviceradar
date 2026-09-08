defmodule ServiceRadar.Observability.AnomalyDisposition.PeakProfile do
  @moduledoc """
  SRQL-backed fetch of the central hour-of-week PEAK profile, for the matched-resolution
  disposition (1.11). [`fetcher/2`] returns the `fetch_peak_profile` function that
  `ServiceRadar.Observability.AnomalyDisposition.for_finding/3` expects.

  Given `%{series_key, metric_class, metric_name, dow, hod}`, it runs the dedicated
  `stats:profile_hour_of_week_peak(value)` SRQL verb (which reads the hourly CAGG's
  `max_value` — the hour-of-week distribution of hourly PEAKS, the right baseline for a
  spike peak, not the diluting mean), then returns `%{center, scale, sample_count}` for
  the matching `(series, dow, hod)` row, or `nil`.

  The verb returns `center` (median peak), `p05`/`p95` (peak percentiles) and
  `bucket_count` per `(series, dow, hod)` — there is no `mad` column. `scale` is derived
  from the upper spread as `(p95 - center) / z₉₅` (z₉₅ ≈ 1.6449), so a peak at p95 scores
  z ≈ 1.645 against the disposition thresholds. The query SELECTs `device_id AS series`,
  so a row is matched by the finding's `device_id` within the metric scope — NOT the
  canonical series_key (the seasonal worker consumes this same device_id-keyed shape).

  The verb name + output columns (`center`/`p05`/`p95`/`bucket_count`) were verified
  against the real SRQL implementation (`rust/srql/src/query/timeseries_metrics.rs`
  `build_profile_hour_of_week_peak_query`) — an earlier `agg:max` + `mad` guess was
  rejected by the live DB.

  Building this fetcher and checking it against a real DB surfaced — and then fixed — a
  CRITICAL routing bug that had also silently broken the production seasonal feed: the
  SRQL translate path dispatched `plan.downsample.is_some()` (set by `bucket:1h`) BEFORE
  the profile route, so a `profile_hour_of_week[_peak]` query routed to the downsample
  builder (rejecting `timezone`) and never reached the profile builders — AND
  `to_sql_and_params` was missing the `_peak` branch. Fixed in `rust/srql`
  (`translate.rs`/`engine.rs` guard + the missing `to_sql_and_params` peak branch);
  verified against the real schema that both `profile_hour_of_week` and
  `profile_hour_of_week_peak` now translate + execute (`{:ok, []}` on empty data). 335
  srql tests pass. Still TODO: a seed-and-fetch e2e (assert real rows yield a correct
  profile) and the alert-engine call-site (report-only).
  """

  alias ServiceRadar.Observability.SRQLRunner

  @default_time_range "180d"
  @default_limit 4000
  @default_timezone "Etc/UTC"
  # standard-normal 95th-percentile z, so a peak at p95 maps to z ≈ 1.645.
  @z95 1.644_853_626_951_472_2

  @doc """
  Build the `fetch_peak_profile.(ctx)` function for `AnomalyDisposition.for_finding/3`.
  `runner` defaults to `SRQLRunner` (override with a stub in tests). Options:
  `:time_range` (default `"180d"`), `:limit`, `:timezone`, `:runner_opts`.
  """
  @spec fetcher(module(), keyword()) :: (map() -> map() | nil)
  def fetcher(runner \\ SRQLRunner, opts \\ []) do
    time_range = Keyword.get(opts, :time_range, @default_time_range)
    limit = Keyword.get(opts, :limit, @default_limit)
    tz = Keyword.get(opts, :timezone, @default_timezone)
    runner_opts = Keyword.get(opts, :runner_opts, [])

    fn ctx ->
      with metric_class when is_binary(metric_class) <- ctx[:metric_class],
           metric_name when is_binary(metric_name) <- ctx[:metric_name],
           query = peak_query(metric_class, metric_name, time_range, limit, tz),
           {:ok, rows} when is_list(rows) <- runner.query(query, runner_opts) do
        find_profile(rows, ctx)
      else
        _ -> nil
      end
    end
  end

  @doc "The SRQL hour-of-week PEAK query (exposed for the DB syntax check / inspection)."
  @spec peak_query(String.t(), String.t(), String.t(), pos_integer(), String.t()) :: String.t()
  def peak_query(metric_class, metric_name, time_range, limit, timezone) do
    ~s|in:timeseries_metrics metric_type:"#{metric_class}" metric_name:"#{metric_name}" time:#{time_range} bucket:1h agg:avg series:uid stats:profile_hour_of_week_peak(value) timezone:"#{timezone}" sort:dow:asc,hod:asc limit:#{limit}|
  end

  defp find_profile(rows, ctx) do
    Enum.find_value(rows, fn row ->
      # SRQL wraps each row's columns under a "payload" key (verified against the real
      # query result); fall back to the row itself for already-flat maps (tests).
      data = Map.get(row, "payload", row)

      with true <- row_matches?(data, ctx),
           center when is_float(center) <- num(field(data, "center")),
           count when is_integer(count) <- int(field(data, "bucket_count")) do
        %{center: center, scale: peak_scale(center, num(field(data, "p95"))), sample_count: count}
      else
        _ -> nil
      end
    end)
  end

  # Upper-spread scale: distance from the median peak to p95, expressed as a sigma.
  # A non-positive/absent spread yields 0.0, which `dispose/3` treats as a hard step.
  defp peak_scale(center, p95) when is_float(p95) and p95 > center, do: (p95 - center) / @z95
  defp peak_scale(_center, _p95), do: 0.0

  # The profile query SELECTs `device_id AS series` (verified in the SQL), so a row is
  # matched by the finding's DEVICE_ID within the metric scope — NOT the canonical
  # series_key (a composite that never equals device_id). For cpu/mem this is one series
  # per device; interface metrics would also need if_index (a later concern).
  defp row_matches?(row, ctx) do
    not is_nil(ctx[:device_id]) and
      field(row, "series") == ctx[:device_id] and
      int(field(row, "dow")) == ctx[:dow] and
      int(field(row, "hod")) == ctx[:hod]
  end

  defp field(row, key) when is_map(row), do: Map.get(row, key)
  defp field(_, _), do: nil

  defp num(v) when is_number(v), do: v * 1.0

  defp num(v) when is_binary(v) do
    case Float.parse(v) do
      {f, _} -> f
      :error -> nil
    end
  end

  defp num(_), do: nil

  defp int(v) when is_integer(v), do: v
  defp int(v) when is_float(v), do: trunc(v)

  defp int(v) when is_binary(v) do
    case Integer.parse(v) do
      {i, _} -> i
      :error -> nil
    end
  end

  defp int(_), do: nil
end
