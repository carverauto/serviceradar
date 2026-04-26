defmodule ServiceRadar.Spatial.Actions.BulkInsertRfObservations do
  @moduledoc """
  Bulk insertion for raw FieldSurvey Sidekick RF observation Arrow batches.
  """
  alias ServiceRadar.Repo

  def run(input, _opts, _context) do
    session_id = Ash.ActionInput.get_argument(input, :session_id)
    observations = Ash.ActionInput.get_argument(input, :observations)
    inserted_at = DateTime.utc_now()

    entries =
      Enum.map(observations, fn observation ->
        captured_at_unix_nanos = Map.fetch!(observation, :captured_at_unix_nanos)

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
          inserted_at: inserted_at
        }
      end)

    case Repo.insert_all("survey_rf_observations", entries, prefix: "platform") do
      {count, _} when count == length(entries) -> {:ok, true}
      _ -> {:ok, false}
    end
  end

  defp unix_nanos_to_datetime!(unix_nanos) when is_integer(unix_nanos) do
    unix_nanos
    |> System.convert_time_unit(:nanosecond, :microsecond)
    |> DateTime.from_unix!(:microsecond)
  end
end
