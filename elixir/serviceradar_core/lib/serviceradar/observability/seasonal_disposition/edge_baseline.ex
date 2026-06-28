defmodule ServiceRadar.Observability.SeasonalDisposition.EdgeBaseline do
  @moduledoc """
  Builds the per-series hour-of-week baseline payload pushed core->edge so the
  anomaly add-on deseasonalizes against the long-horizon central profile instead
  of only its short rolling window (OpenSpec task 2.6).

  Input is the same 168-bucket hour-of-week profile rows the
  `SeasonalDisposition.Worker` already hydrates from
  `stats:profile_hour_of_week(value)` over the hourly CAGGs — one row per
  `(series, dow, hod)` carrying the robust order statistics (`center`/`mad` or
  `center`/`p05`/`p95`) or the mean/stddev moments (`bucket_count`/`bucket_sum`/
  `bucket_sum_sq`). This module reduces each bucket to the compact
  `{center, scale}` summary the edge `serviceradar-anomaly-core` seasonal signal
  consumes and groups them by series key.

  The output map matches the add-on `config.schema.json` `seasonal_baselines`
  shape exactly, ready to JSON-encode into the established add-on config channel:

      %{
        "<series_key>" => %{
          "buckets" => [
            %{"dow" => 1, "hod" => 9, "center" => 70.0, "scale" => 2.97, "sample_count" => 8},
            ...
          ]
        }
      }

  The center is a robust MEDIAN for the robust statistics (so a single recurring
  incident hour cannot poison the baseline — the whole point), and the dispersion
  `scale` is converted to a sigma-consistent estimate so the edge z-score
  `(value - center) / scale` matches a normal-baseline 3-sigma gate.
  """

  # z for the 95th/5th percentiles of a normal: 2 * 1.6448536269514722.
  @p05p95_sigma_span 3.2897072539029457
  # MAD -> sigma consistency constant for a normal distribution.
  @mad_to_sigma 1.4826

  @doc """
  Build the per-series `seasonal_baselines` payload from hydrated profile rows.

  `robust_statistic` selects how each bucket's `{center, scale}` is derived and
  defaults to `:median_mad` (the worker's default). Rows missing required fields,
  with an out-of-range `(dow, hod)`, or a non-finite/negative scale are dropped.
  """
  @spec build([map()], atom()) :: %{optional(String.t()) => map()}
  def build(rows, robust_statistic \\ :median_mad) when is_list(rows) do
    rows
    |> Enum.flat_map(&wrap_bucket(&1, robust_statistic))
    |> Enum.group_by(fn {series_key, _bucket} -> series_key end, fn {_series_key, bucket} ->
      bucket
    end)
    |> Map.new(fn {series_key, buckets} -> {series_key, %{"buckets" => buckets}} end)
  end

  defp wrap_bucket(row, robust_statistic) when is_map(row) do
    with series_key when is_binary(series_key) and series_key != "" <- get(row, :series_key),
         dow when is_integer(dow) and dow in 0..6 <- get(row, :dow),
         hod when is_integer(hod) and hod in 0..23 <- get(row, :hod),
         {:ok, center, scale} <- center_scale(row, robust_statistic),
         true <- is_number(center) and is_number(scale) and scale >= 0.0 do
      [
        {series_key,
         %{
           "dow" => dow,
           "hod" => hod,
           "center" => center * 1.0,
           "scale" => scale * 1.0,
           "sample_count" => sample_count(row)
         }}
      ]
    else
      _ -> []
    end
  end

  defp wrap_bucket(_row, _robust_statistic), do: []

  defp center_scale(row, :mean_stddev) do
    with count when is_integer(count) and count > 1 <- get(row, :bucket_count),
         sum when is_number(sum) <- get(row, :bucket_sum),
         sum_sq when is_number(sum_sq) <- get(row, :bucket_sum_sq) do
      mean = sum / count
      variance = max(0.0, (sum_sq - sum * mean) / (count - 1))
      {:ok, mean, :math.sqrt(variance)}
    else
      _ -> :error
    end
  end

  defp center_scale(row, :p05p95) do
    with center when is_number(center) <- get(row, :center),
         p05 when is_number(p05) <- get(row, :p05),
         p95 when is_number(p95) <- get(row, :p95) do
      {:ok, center, max(0.0, (p95 - p05) / @p05p95_sigma_span)}
    else
      _ -> :error
    end
  end

  # Default + :median_mad: a median center with a MAD-derived sigma scale.
  defp center_scale(row, _robust_statistic) do
    with center when is_number(center) <- get(row, :center),
         mad when is_number(mad) <- get(row, :mad) do
      {:ok, center, max(0.0, mad * @mad_to_sigma)}
    else
      _ -> :error
    end
  end

  defp sample_count(row) do
    case get(row, :bucket_count) do
      count when is_integer(count) and count >= 0 -> count
      count when is_float(count) and count >= 0.0 -> trunc(count)
      _ -> 0
    end
  end

  defp get(row, key) when is_map(row) do
    Map.get(row, key, Map.get(row, to_string(key)))
  end
end
