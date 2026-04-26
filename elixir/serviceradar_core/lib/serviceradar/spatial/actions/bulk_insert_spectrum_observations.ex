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
end
