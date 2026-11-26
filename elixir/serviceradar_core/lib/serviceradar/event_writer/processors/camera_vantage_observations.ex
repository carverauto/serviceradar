defmodule ServiceRadar.EventWriter.Processors.CameraVantageObservations do
  @moduledoc """
  Stores Vantage ML observation results (`media.results.vantage.v1`, on the
  worker-owned `CAMERA_MEDIA_RESULTS` stream) through
  `ServiceRadar.Camera.VantageObservationProjector`.
  """

  @behaviour ServiceRadar.EventWriter.Processor

  alias Broadway.Message
  alias ServiceRadar.Camera.VantageObservationProjector
  alias ServiceRadar.EventWriter.TerminalMessageError
  alias ServiceRadar.EventWriter.TransientMessageError

  @impl true
  def table_name, do: "camera_vantage_observations"

  @impl true
  def process_batch(messages) do
    {stored, failures} =
      Enum.reduce(messages, {0, []}, fn message, {stored, failures} ->
        case store(message) do
          {:ok, count} -> {stored + count, failures}
          {:error, error} -> {stored, [{message, error} | failures]}
        end
      end)

    case failures do
      [] -> {:ok, stored}
      _ -> {:incomplete, stored, Enum.reverse(failures)}
    end
  end

  defp store(%Message{data: data}) do
    case VantageObservationProjector.ingest_result(data) do
      {:ok, %{observation_count: count}} -> {:ok, count}
      {:error, :recording_gone} -> {:ok, 0}
      {:error, reason} -> classify_error(reason)
    end
  rescue
    error -> {:error, %TransientMessageError{reason: error}}
  end

  defp classify_error(reason) do
    if VantageObservationProjector.terminal_drop?(reason),
      do: {:error, %TerminalMessageError{reason: reason}},
      else: {:error, %TransientMessageError{reason: reason}}
  end
end
