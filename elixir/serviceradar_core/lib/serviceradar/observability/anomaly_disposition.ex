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

  defp get(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
  defp get(_, _), do: nil

  defp num(v) when is_number(v), do: v * 1.0
  defp num(_), do: nil

  defp int(v) when is_number(v), do: trunc(v)
  defp int(_), do: 0

  defp fmt(z), do: :erlang.float_to_binary(z, decimals: 2)
end
