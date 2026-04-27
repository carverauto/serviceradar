defmodule ServiceRadar.Spatial.Actions.BulkInsertSpectrumObservations do
  @moduledoc """
  Bulk insertion for raw FieldSurvey Sidekick SDR spectrum Arrow batches.
  """
  alias ServiceRadar.Repo

  @max_rows_per_batch 2_000

  def run(input, _opts, _context) do
    session_id = Ash.ActionInput.get_argument(input, :session_id)
    observations = Ash.ActionInput.get_argument(input, :observations)
    inserted_at = DateTime.utc_now()

    with true <- valid_session_id?(session_id),
         true <- is_list(observations),
         true <- length(observations) <= @max_rows_per_batch,
         {:ok, entries} <- build_entries(session_id, observations, inserted_at) do
      case insert_entries(entries) do
        {:ok, count} when count == length(entries) -> {:ok, true}
        _ -> {:ok, false}
      end
    else
      _ -> {:ok, false}
    end
  end

  defp insert_entries([]), do: {:ok, 0}

  defp insert_entries(entries) do
    payload =
      entries
      |> Enum.map(&json_ready_entry/1)
      |> Jason.encode!()

    case Repo.query(insert_sql(), [payload]) do
      {:ok, %{num_rows: count}} -> {:ok, count}
      {:error, _reason} -> {:error, :insert_failed}
    end
  end

  defp json_ready_entry(entry) do
    entry
    |> Map.update!(:started_at, &DateTime.to_iso8601/1)
    |> Map.update!(:captured_at, &DateTime.to_iso8601/1)
    |> Map.update!(:inserted_at, &DateTime.to_iso8601/1)
  end

  defp insert_sql do
    """
    INSERT INTO platform.survey_spectrum_observations (
      session_id,
      sidekick_id,
      sdr_id,
      device_kind,
      serial_number,
      sweep_id,
      started_at,
      started_at_unix_nanos,
      captured_at,
      captured_at_unix_nanos,
      start_frequency_hz,
      stop_frequency_hz,
      bin_width_hz,
      sample_count,
      power_bins_dbm,
      power_features,
      inserted_at
    )
    SELECT
      session_id,
      sidekick_id,
      sdr_id,
      device_kind,
      serial_number,
      sweep_id,
      started_at,
      started_at_unix_nanos,
      captured_at,
      captured_at_unix_nanos,
      start_frequency_hz,
      stop_frequency_hz,
      bin_width_hz,
      sample_count,
      power_bins_dbm,
      NULLIF(power_features, '')::vector(8),
      inserted_at
    FROM jsonb_to_recordset($1::text::jsonb) AS rows(
      session_id text,
      sidekick_id text,
      sdr_id text,
      device_kind text,
      serial_number text,
      sweep_id bigint,
      started_at timestamptz,
      started_at_unix_nanos bigint,
      captured_at timestamptz,
      captured_at_unix_nanos bigint,
      start_frequency_hz bigint,
      stop_frequency_hz bigint,
      bin_width_hz double precision,
      sample_count integer,
      power_bins_dbm double precision[],
      power_features text,
      inserted_at timestamptz
    )
    """
  end

  defp build_entries(session_id, observations, inserted_at) do
    observations
    |> Enum.reduce_while({:ok, []}, fn observation, {:ok, entries} ->
      case safe_build_entry(session_id, observation, inserted_at) do
        {:ok, entry} -> {:cont, {:ok, [entry | entries]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp safe_build_entry(session_id, observation, inserted_at) do
    build_entry(session_id, observation, inserted_at)
  rescue
    _ -> {:error, :invalid_spectrum_observation}
  end

  defp build_entry(session_id, observation, inserted_at) when is_map(observation) do
    with {:ok, started_at_unix_nanos} <- fetch_integer(observation, :started_at_unix_nanos),
         {:ok, captured_at_unix_nanos} <- fetch_integer(observation, :captured_at_unix_nanos),
         true <- is_list(Map.get(observation, :power_bins_dbm, [])) do
      {:ok,
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
       }}
    else
      _ -> {:error, :invalid_spectrum_observation}
    end
  end

  defp build_entry(_session_id, _observation, _inserted_at), do: {:error, :invalid_spectrum_observation}

  defp valid_session_id?(session_id), do: is_binary(session_id) and byte_size(session_id) <= 128

  defp fetch_integer(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_integer(value) -> {:ok, value}
      _ -> {:error, {:invalid_integer, key}}
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

    variance =
      Enum.reduce(bins, 0.0, fn value, acc -> acc + :math.pow(value - avg, 2) end) / count

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
