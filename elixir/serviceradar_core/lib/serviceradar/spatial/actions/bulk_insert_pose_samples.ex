defmodule ServiceRadar.Spatial.Actions.BulkInsertPoseSamples do
  @moduledoc """
  Bulk insertion for iOS pose Arrow batches used in RF/pose fusion.
  """
  alias ServiceRadar.Repo

  @max_rows_per_batch 10_000

  def run(input, _opts, _context) do
    session_id = Ash.ActionInput.get_argument(input, :session_id)
    samples = Ash.ActionInput.get_argument(input, :samples)
    inserted_at = DateTime.utc_now()

    with true <- valid_session_id?(session_id),
         true <- is_list(samples),
         true <- length(samples) <= @max_rows_per_batch,
         {:ok, entries} <- build_entries(session_id, samples, inserted_at) do
      fn ->
        case Repo.insert_all("survey_pose_samples", entries, prefix: "platform") do
          {count, _} when count == length(entries) -> true
          _ -> Repo.rollback(:insert_count_mismatch)
        end
      end
      |> Repo.transaction()
      |> case do
        {:ok, true} -> {:ok, true}
        {:error, _reason} -> {:ok, false}
      end
    else
      _ -> {:ok, false}
    end
  end

  defp build_entries(session_id, samples, inserted_at) do
    samples
    |> Enum.reduce_while({:ok, []}, fn sample, {:ok, entries} ->
      case safe_build_entry(session_id, sample, inserted_at) do
        {:ok, entry} -> {:cont, {:ok, [entry | entries]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp safe_build_entry(session_id, sample, inserted_at) do
    build_entry(session_id, sample, inserted_at)
  rescue
    _ -> {:error, :invalid_sample}
  end

  defp build_entry(session_id, sample, inserted_at) when is_map(sample) do
    with {:ok, captured_at_unix_nanos} <- fetch_integer(sample, :captured_at_unix_nanos) do
      {:ok,
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
       }}
    end
  end

  defp build_entry(_session_id, _sample, _inserted_at), do: {:error, :invalid_sample}

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
end
