defmodule ServiceRadar.Spatial.Actions.BulkInsertSamples do
  @moduledoc """
  High performance bulk insertion logic for streaming Arrow IPC arrays
  into TimescaleDB / PostGIS hypertables.
  """
  use Ash.Resource.Change

  alias ServiceRadar.Repo

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
            rf_vector: format_vector(Map.get(sample, :rf_vector, "")),
            ble_vector: format_vector(Map.get(sample, :ble_vector, ""))
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
  
  # Converts the comma-separated string from the Arrow Stream back into a proper PostGIS pgvector format.
  defp format_vector(nil), do: "[]"
  defp format_vector(""), do: "[]"
  defp format_vector(str) do
    "[" <> str <> "]"
  end
end