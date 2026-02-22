defmodule ServiceRadar.Spatial.Actions.BulkInsertSamples do
  @moduledoc """
  High performance bulk insertion logic for streaming Arrow IPC arrays
  into TimescaleDB / PostGIS hypertables.
  """
  use Ash.Resource.Change

  alias ServiceRadar.Repo
  @rf_vector_dims 64
  @ble_vector_dims 64
  @missing_signal_value -100.0

  def change(changeset, _opts, _context) do
    Ash.Changeset.after_transaction(changeset, fn _changeset, _result ->
      session_id = Ash.Changeset.get_argument(changeset, :session_id)
      samples = Ash.Changeset.get_argument(changeset, :samples)

      now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

      # Transform decoded Arrow maps into raw Ecto schema maps for Repo.insert_all
      entries =
        Enum.map(samples, fn sample ->
          %{
            id: Ecto.UUID.generate(),
            session_id: session_id,
            scanner_device_id: Map.get(sample, :scanner_device_id, "unknown"),
            timestamp: now,
            bssid: Map.get(sample, :bssid, ""),
            ssid: Map.get(sample, :ssid, ""),
            rssi: Map.get(sample, :rssi, 0.0),
            frequency: Map.get(sample, :frequency, 0),
            security_type: Map.get(sample, :security_type, "Unknown"),
            is_secure: Map.get(sample, :is_secure, false),
            x: Map.get(sample, :x, 0.0),
            y: Map.get(sample, :y, 0.0),
            z: Map.get(sample, :z, 0.0),
            latitude: Map.get(sample, :latitude, 0.0),
            longitude: Map.get(sample, :longitude, 0.0),
            uncertainty: Map.get(sample, :uncertainty, 1.0),
            rf_vector: format_vector(Map.get(sample, :rf_vector, ""), @rf_vector_dims),
            ble_vector: format_vector(Map.get(sample, :ble_vector, ""), @ble_vector_dims)
          }
        end)

      # High-performance bulk insert bypasses Ash overhead for telemetry streams
      case Repo.insert_all("survey_samples", entries) do
        {count, _} when count == length(entries) ->
          {:ok, true}

        _ ->
          {:ok, false}
      end
    end)
  end

  # Converts Arrow payload vectors to fixed-size pgvector literals.
  defp format_vector(value, dims) do
    values =
      value
      |> parse_vector_values()
      |> Enum.filter(&is_number/1)
      |> Enum.map(&clamp_signal/1)
      |> normalize_vector(dims)

    "[" <> Enum.map_join(values, ",", &to_string/1) <> "]"
  end

  defp parse_vector_values(nil), do: []
  defp parse_vector_values(""), do: []

  defp parse_vector_values(str) when is_binary(str) do
    str
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.map(fn token ->
      case Float.parse(token) do
        {value, ""} -> value
        _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_vector_values(list) when is_list(list), do: list
  defp parse_vector_values(_value), do: []

  defp normalize_vector(values, dims) do
    trimmed = Enum.take(values, dims)
    trimmed ++ List.duplicate(@missing_signal_value, dims - length(trimmed))
  end

  defp clamp_signal(value) when is_integer(value), do: clamp_signal(value * 1.0)
  defp clamp_signal(value) when value < -100.0, do: -100.0
  defp clamp_signal(value) when value > 0.0, do: 0.0
  defp clamp_signal(value), do: value
end
