defmodule ServiceRadar.Spatial.Actions.BulkInsertPoseSamples do
  @moduledoc """
  Bulk insertion for iOS pose Arrow batches used in RF/pose fusion.
  """
  alias ServiceRadar.Repo

  def run(input, _opts, _context) do
    session_id = Ash.ActionInput.get_argument(input, :session_id)
    samples = Ash.ActionInput.get_argument(input, :samples)
    inserted_at = DateTime.utc_now()

    entries =
      Enum.map(samples, fn sample ->
        captured_at_unix_nanos = Map.fetch!(sample, :captured_at_unix_nanos)

        %{
          session_id: session_id,
          scanner_device_id: Map.get(sample, :scanner_device_id, "unknown"),
          captured_at: unix_nanos_to_datetime!(captured_at_unix_nanos),
          captured_at_unix_nanos: captured_at_unix_nanos,
          captured_at_monotonic_nanos: Map.get(sample, :captured_at_monotonic_nanos),
          x: Map.get(sample, :x, 0.0),
          y: Map.get(sample, :y, 0.0),
          z: Map.get(sample, :z, 0.0),
          qx: Map.get(sample, :qx, 0.0),
          qy: Map.get(sample, :qy, 0.0),
          qz: Map.get(sample, :qz, 0.0),
          qw: Map.get(sample, :qw, 1.0),
          latitude: Map.get(sample, :latitude),
          longitude: Map.get(sample, :longitude),
          altitude: Map.get(sample, :altitude),
          accuracy_m: Map.get(sample, :accuracy_m),
          tracking_quality: Map.get(sample, :tracking_quality),
          inserted_at: inserted_at
        }
      end)

    case Repo.insert_all("survey_pose_samples", entries, prefix: "platform") do
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
