defmodule ServiceRadar.Observability.AnomalyDisposition do
  @moduledoc """
  Matched-resolution disposition for an edge spike finding (1c; absorbs the
  `add-anomaly-finding-disposition` #4280 "Option B" decision).

  The edge fires on a sub-minute spike; judging it against the central hourly-MEAN
  seasonal verdict is a resolution mismatch (a 30s 99% spike diluted into a 12% hourly
  mean looks "seasonally normal", so suppressing the spike on that basis is unsound).
  Instead this compares the spike's forwarded **peak** against the series' hour-of-week
  **peak** profile (built from `timeseries_metrics_hourly.max_value`, the F19 peak verb):

    * peak within the profile  -> recurring/expected spike  -> `:suppress`
    * peak above the profile   -> novel for this hour       -> `:escalate`
    * modestly elevated        ->                              `:downgrade`
    * thin/absent profile or no forwarded peak               -> `:pass_through`

  Pure function — no I/O. The caller (alert engine / device-detail panel) applies the
  disposition **report-only behind a per-metric-class kill switch** until the peak
  profile is stable (the safety contract: a report-only disposition can never suppress
  a real alert; it only annotates).
  """

  alias ServiceRadar.Observability.AnomalyDetection.SeriesKey
  alias ServiceRadar.Observability.AnomalyDisposition.PeakProfile
  alias ServiceRadar.Observability.SRQLRunner

  @telemetry_event [:serviceradar, :anomaly, :disposition]

  @type disposition :: :suppress | :downgrade | :escalate | :pass_through

  @default_escalate_sigma 3.0
  @default_suppress_sigma 1.0
  @default_min_samples 4

  @doc """
  Dispose an edge spike given the central hour-of-week PEAK profile.

  `edge` carries `:peak_value` (the forwarded spike peak). `peak_profile` carries the
  robust `:center` and stddev-equivalent `:scale` of the series' hour-of-week peak plus
  its effective `:sample_count`. Both maps accept atom or string keys (wire payloads).
  Returns `{disposition, reason}`.
  """
  @spec dispose(map(), map(), keyword()) :: {disposition(), String.t()}
  def dispose(edge, peak_profile, opts \\ []) do
    escalate_sigma = Keyword.get(opts, :escalate_sigma, @default_escalate_sigma)
    suppress_sigma = Keyword.get(opts, :suppress_sigma, @default_suppress_sigma)
    min_samples = Keyword.get(opts, :min_samples, @default_min_samples)

    peak = num(get(edge, :peak_value))
    center = num(get(peak_profile, :center))
    scale = num(get(peak_profile, :scale))
    count = int(get(peak_profile, :sample_count))

    cond do
      is_nil(peak) ->
        {:pass_through, "edge finding has no forwarded peak"}

      is_nil(center) or is_nil(scale) or count < min_samples ->
        {:pass_through, "insufficient peak profile (#{count} samples)"}

      scale <= 0.0 ->
        if peak > center do
          {:escalate, "peak above a zero-variance peak profile"}
        else
          {:suppress, "peak at the constant peak profile"}
        end

      true ->
        z = (peak - center) / scale

        cond do
          z >= escalate_sigma ->
            {:escalate, "spike peak is novel for this hour (z=#{fmt(z)})"}

          z <= suppress_sigma ->
            {:suppress, "spike peak is within the hour-of-week profile (recurring; z=#{fmt(z)})"}

          true ->
            {:downgrade, "spike peak is modestly elevated for this hour (z=#{fmt(z)})"}
        end
    end
  end

  @doc """
  Whether a disposition may ACT (actually suppress/downgrade an alert) vs be applied
  report-only. Gated on (a) the per-metric-class kill switch `:suppression_enabled`
  (default `false` — report-only is the safety default until a class's peak profile is
  proven stable) and (b) peak-profile stability (`>= :min_stable_samples` effective
  samples and a finite center/scale). This is the 1.12 stability gate: a report-only
  disposition is recorded and surfaced but never removes a real alert.
  """
  @spec actionable?(map(), keyword()) :: boolean()
  def actionable?(peak_profile, opts \\ []) do
    enabled = Keyword.get(opts, :suppression_enabled, false)
    min_stable = Keyword.get(opts, :min_stable_samples, 6)
    count = int(get(peak_profile, :sample_count))
    center = num(get(peak_profile, :center))
    scale = num(get(peak_profile, :scale))

    enabled and count >= min_stable and not is_nil(center) and not is_nil(scale) and scale >= 0.0
  end

  @doc """
  On-demand disposition for an edge anomaly finding (1.11 orchestration).

  Re-keys the finding from its `source_identity` (the F14 canonical `series_key`), reads
  the forwarded `episode_peak_value`, derives the (dow, hod) of `episode_peak_at_unix_nano`
  (Postgres `EXTRACT(DOW)` convention: Sun=0..Sat=6), fetches the central hour-of-week
  PEAK profile via the injected `fetch_peak_profile.(ctx)`, and disposes.

  `ctx` is `%{series_key, metric_class, metric_name, dow, hod}` — it carries the
  metric_class/metric_name because the SRQL peak query (mirroring
  `seasonal_disposition/source.ex` `profile_query/5`) scopes the table read by
  `metric_type`/`metric_name`, not just the series. The alert/query layer supplies the
  SRQL-backed fetch; tests supply a stub.

  Returns `%{series_key, disposition, reason, actionable, peak_value, dow, hod}`, or `nil`
  when the finding lacks the canonical key, a forwarded peak, or a peak timestamp.
  """
  @spec for_finding(map(), (map() -> map() | nil), keyword()) :: map() | nil
  def for_finding(finding, fetch_peak_profile, opts \\ [])
      when is_map(finding) and is_function(fetch_peak_profile, 1) do
    source_identity = get(finding, :source_identity) || %{}
    series_key = SeriesKey.from_source_identity(source_identity)
    peak = num(get(finding, :episode_peak_value))
    how = finding_hour_of_week(finding)

    if is_nil(series_key) or is_nil(peak) or is_nil(how) do
      nil
    else
      {dow, hod} = how

      ctx = %{
        series_key: series_key,
        device_id: get(source_identity, :device_id),
        metric_class: get(source_identity, :metric_class),
        metric_name: get(source_identity, :metric_name),
        dow: dow,
        hod: hod
      }

      profile = fetch_peak_profile.(ctx) || %{}
      {disposition, reason} = dispose(%{peak_value: peak}, profile, opts)

      %{
        series_key: series_key,
        disposition: disposition,
        reason: reason,
        actionable: actionable?(profile, opts),
        peak_value: peak,
        dow: dow,
        hod: hod
      }
    end
  end

  @doc """
  Report-only disposition for an edge anomaly finding (1.11/1.13), the out-of-band
  entry point a class-2004 consumer calls (NOT the alert hot path). Builds the
  SRQL-backed peak-profile fetcher, computes the disposition via [`for_finding/3`], and
  emits it as telemetry `[:serviceradar, :anomaly, :disposition]` (measurement `count: 1`,
  the disposition map as metadata) WITHOUT changing any alert — suppression stays gated
  by [`actionable?/2`] behind the per-metric-class kill switch. Returns the disposition
  map, or `:ignore` when the finding can't be disposed (no peak, no canonical key, etc.).

  `:runner` (default `SRQLRunner`) and the `dispose/3`/`fetcher/2` options pass through.
  """
  @spec report_finding(map(), keyword()) :: map() | :ignore
  def report_finding(finding, opts \\ []) do
    runner = Keyword.get(opts, :runner, SRQLRunner)
    fetcher = PeakProfile.fetcher(runner, opts)

    case for_finding(finding, fetcher, opts) do
      %{} = result ->
        :telemetry.execute(@telemetry_event, %{count: 1}, result)
        result

      _ ->
        :ignore
    end
  end

  defp finding_hour_of_week(finding) do
    case get(finding, :episode_peak_at_unix_nano) || get(finding, :time) do
      nil -> nil
      v -> to_hour_of_week(v)
    end
  end

  defp to_hour_of_week(nano) when is_integer(nano) do
    case DateTime.from_unix(nano, :nanosecond) do
      {:ok, dt} -> {rem(Date.day_of_week(DateTime.to_date(dt)), 7), dt.hour}
      _ -> nil
    end
  end

  defp to_hour_of_week(%DateTime{} = dt),
    do: {rem(Date.day_of_week(DateTime.to_date(dt)), 7), dt.hour}

  defp to_hour_of_week(_), do: nil

  defp get(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
  defp get(_, _), do: nil

  defp num(v) when is_number(v), do: v * 1.0
  defp num(_), do: nil

  defp int(v) when is_number(v), do: trunc(v)
  defp int(_), do: 0

  defp fmt(z), do: :erlang.float_to_binary(z, decimals: 2)
end
