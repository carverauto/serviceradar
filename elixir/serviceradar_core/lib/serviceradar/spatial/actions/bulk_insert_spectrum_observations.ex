defmodule ServiceRadar.Spatial.Actions.BulkInsertSpectrumObservations do
  @moduledoc """
  Bulk insertion for raw FieldSurvey Sidekick SDR spectrum Arrow batches.
  """
  alias ServiceRadar.Repo

  def run(input, _opts, _context) do
    session_id = Ash.ActionInput.get_argument(input, :session_id)
    observations = Ash.ActionInput.get_argument(input, :observations)
    inserted_at = DateTime.utc_now()

    entries =
      Enum.map(observations, fn observation ->
        started_at_unix_nanos = Map.fetch!(observation, :started_at_unix_nanos)
        captured_at_unix_nanos = Map.fetch!(observation, :captured_at_unix_nanos)

        %{
          session_id: session_id,
          sidekick_id: Map.get(observation, :sidekick_id, "unknown"),
          sdr_id: Map.get(observation, :sdr_id, "unknown"),
          device_kind: Map.get(observation, :device_kind, "unknown"),
          serial_number: Map.get(observation, :serial_number),
          sweep_id: Map.get(observation, :sweep_id, 0),
          started_at: unix_nanos_to_datetime!(started_at_unix_nanos),
          started_at_unix_nanos: started_at_unix_nanos,
          captured_at: unix_nanos_to_datetime!(captured_at_unix_nanos),
          captured_at_unix_nanos: captured_at_unix_nanos,
          start_frequency_hz: Map.get(observation, :start_frequency_hz, 0),
          stop_frequency_hz: Map.get(observation, :stop_frequency_hz, 0),
          bin_width_hz: Map.get(observation, :bin_width_hz, 0.0),
          sample_count: Map.get(observation, :sample_count, 0),
          power_bins_dbm: Map.get(observation, :power_bins_dbm, []),
          power_features: power_features(observation),
          inserted_at: inserted_at
        }
      end)

    case Repo.insert_all("survey_spectrum_observations", entries, prefix: "platform") do
      {count, _} when count == length(entries) -> {:ok, true}
      _ -> {:ok, false}
    end
  end

  defp unix_nanos_to_datetime!(unix_nanos) when is_integer(unix_nanos) do
    unix_nanos
    |> System.convert_time_unit(:nanosecond, :microsecond)
    |> DateTime.from_unix!(:microsecond)
  end

  defp power_features(observation) do
    bins = Map.get(observation, :power_bins_dbm, [])
    {min_power, max_power, avg_power, stddev_power} = power_stats(bins)

    vector_literal([
      normalize_frequency_hz(Map.get(observation, :start_frequency_hz, 0)),
      normalize_frequency_hz(Map.get(observation, :stop_frequency_hz, 0)),
      normalize_bin_width(Map.get(observation, :bin_width_hz, 0.0)),
      normalize_sample_count(Map.get(observation, :sample_count, length(bins))),
      normalize_dbm(min_power),
      normalize_dbm(max_power),
      normalize_dbm(avg_power),
      normalize_dbm(stddev_power)
    ])
  end

  defp power_stats([]), do: {-128.0, -128.0, -128.0, 0.0}

  defp power_stats(bins) do
    count = length(bins)
    sum = Enum.sum(bins)
    avg = sum / count
    variance = Enum.reduce(bins, 0.0, fn value, acc -> acc + :math.pow(value - avg, 2) end) / count

    {Enum.min(bins), Enum.max(bins), avg, :math.sqrt(variance)}
  end

  defp normalize_frequency_hz(value), do: clamp_float(value / 7_125_000_000.0, 0.0, 1.0)
  defp normalize_bin_width(value), do: clamp_float(value / 20_000_000.0, 0.0, 1.0)
  defp normalize_sample_count(value), do: clamp_float(value / 4_096.0, 0.0, 1.0)
  defp normalize_dbm(value), do: clamp_float(value / 128.0, -1.0, 1.0)

  defp clamp_float(value, min, max) when is_integer(value), do: clamp_float(value * 1.0, min, max)

  defp clamp_float(value, min, max) when is_float(value) do
    value
    |> max(min)
    |> min(max)
  end

  defp vector_literal(values), do: "[" <> Enum.map_join(values, ",", &to_string/1) <> "]"
end
