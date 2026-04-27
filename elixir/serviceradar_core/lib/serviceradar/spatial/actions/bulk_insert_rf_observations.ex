defmodule ServiceRadar.Spatial.Actions.BulkInsertRfObservations do
  @moduledoc """
  Bulk insertion for raw FieldSurvey Sidekick RF observation Arrow batches.
  """
  alias ServiceRadar.Repo

  @max_rows_per_batch 10_000

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
    |> Map.update!(:captured_at, &DateTime.to_iso8601/1)
    |> Map.update!(:inserted_at, &DateTime.to_iso8601/1)
  end

  defp insert_sql do
    """
    INSERT INTO platform.survey_rf_observations (
      session_id,
      sidekick_id,
      radio_id,
      interface_name,
      bssid,
      ssid,
      hidden_ssid,
      frame_type,
      rssi_dbm,
      noise_floor_dbm,
      snr_db,
      frequency_mhz,
      channel,
      channel_width_mhz,
      captured_at,
      captured_at_unix_nanos,
      captured_at_monotonic_nanos,
      parser_confidence,
      rf_features,
      inserted_at
    )
    SELECT
      session_id,
      sidekick_id,
      radio_id,
      interface_name,
      bssid,
      ssid,
      hidden_ssid,
      frame_type,
      rssi_dbm,
      noise_floor_dbm,
      snr_db,
      frequency_mhz,
      channel,
      channel_width_mhz,
      captured_at,
      captured_at_unix_nanos,
      captured_at_monotonic_nanos,
      parser_confidence,
      NULLIF(rf_features, '')::vector(8),
      inserted_at
    FROM jsonb_to_recordset($1::text::jsonb) AS rows(
      session_id text,
      sidekick_id text,
      radio_id text,
      interface_name text,
      bssid text,
      ssid text,
      hidden_ssid boolean,
      frame_type text,
      rssi_dbm smallint,
      noise_floor_dbm smallint,
      snr_db smallint,
      frequency_mhz integer,
      channel integer,
      channel_width_mhz integer,
      captured_at timestamptz,
      captured_at_unix_nanos bigint,
      captured_at_monotonic_nanos bigint,
      parser_confidence double precision,
      rf_features text,
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
    _ -> {:error, :invalid_observation}
  end

  defp build_entry(session_id, observation, inserted_at) when is_map(observation) do
    with {:ok, captured_at_unix_nanos} <- fetch_integer(observation, :captured_at_unix_nanos) do
      {:ok,
       %{
         session_id: session_id,
         sidekick_id: Map.get(observation, :sidekick_id, "unknown"),
         radio_id: Map.get(observation, :radio_id, "unknown"),
         interface_name: Map.get(observation, :interface_name, "unknown"),
         bssid: Map.get(observation, :bssid, ""),
         ssid: Map.get(observation, :ssid),
         hidden_ssid: Map.get(observation, :hidden_ssid, true),
         frame_type: Map.get(observation, :frame_type, "other"),
         rssi_dbm: Map.get(observation, :rssi_dbm),
         noise_floor_dbm: Map.get(observation, :noise_floor_dbm),
         snr_db: Map.get(observation, :snr_db),
         frequency_mhz: Map.get(observation, :frequency_mhz, 0),
         channel: Map.get(observation, :channel),
         channel_width_mhz: Map.get(observation, :channel_width_mhz),
         captured_at: unix_nanos_to_datetime!(captured_at_unix_nanos),
         captured_at_unix_nanos: captured_at_unix_nanos,
         captured_at_monotonic_nanos: Map.get(observation, :captured_at_monotonic_nanos),
         parser_confidence: Map.get(observation, :parser_confidence, 0.0),
         rf_features: rf_features(observation),
         inserted_at: inserted_at
       }}
    end
  end

  defp build_entry(_session_id, _observation, _inserted_at), do: {:error, :invalid_observation}

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

  defp rf_features(observation) do
    vector_literal([
      normalize_dbm(Map.get(observation, :rssi_dbm), -128),
      normalize_dbm(Map.get(observation, :noise_floor_dbm), -128),
      normalize_snr(Map.get(observation, :snr_db)),
      normalize_frequency(Map.get(observation, :frequency_mhz, 0)),
      normalize_channel(Map.get(observation, :channel)),
      normalize_width(Map.get(observation, :channel_width_mhz)),
      clamp_float(Map.get(observation, :parser_confidence, 0.0), 0.0, 1.0),
      if(Map.get(observation, :hidden_ssid, true), do: 1.0, else: 0.0)
    ])
  end

  defp normalize_dbm(nil, default), do: default / 128.0
  defp normalize_dbm(value, _default), do: clamp_float(value / 128.0, -1.0, 1.0)

  defp normalize_snr(nil), do: 0.0
  defp normalize_snr(value), do: clamp_float(value / 100.0, -1.0, 1.0)

  defp normalize_frequency(value), do: clamp_float(value / 7_125.0, 0.0, 1.0)

  defp normalize_channel(nil), do: 0.0
  defp normalize_channel(value), do: clamp_float(value / 233.0, 0.0, 1.0)

  defp normalize_width(nil), do: 0.0
  defp normalize_width(value), do: clamp_float(value / 320.0, 0.0, 1.0)

  defp clamp_float(value, min, max) when is_integer(value), do: clamp_float(value * 1.0, min, max)

  defp clamp_float(value, min, max) when is_float(value) do
    value
    |> max(min)
    |> min(max)
  end

  defp vector_literal(values), do: "[" <> Enum.map_join(values, ",", &to_string/1) <> "]"
end
