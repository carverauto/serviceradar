defmodule ServiceRadar.EventWriter.Processors.CameraVisualIndexResults do
  @moduledoc """
  Stores media worker visual index results (`media.results.visual_index.v1`,
  on the worker-owned `CAMERA_MEDIA_RESULTS` stream) through
  `ServiceRadar.Camera.VisualIndexResultProjector`, the only writer of visual
  frames and embeddings.

  Each message is stored on its own, in its own transaction:

    * stored, or a replay of a stored result: acknowledged. The projector
      skips projection for completed, cancelled and terminally failed jobs.
    * the recording was deleted or quarantined while the worker ran:
      acknowledged. The projector stores nothing and cancels the entry's jobs.
    * a result that can never be stored
      (`VisualIndexResultProjector.terminal_drop?/1`): when identity matches and the database accepts the update,
      the admitted job is marked `:failed_terminal` with the failure class (and a best-effort `TripwireHealth`
      record), then the message fails with
      `ServiceRadar.EventWriter.TerminalMessageError`, which terminates it as a
      dead letter. A failed update is transient. If the database is unavailable for all
      ten deliveries of a permanently invalid result, the tenth delivery is terminated
      while the job is still dispatched. After the retention floor and deadline pass,
      expired-job reconciliation republishes the next attempt or marks the job
      `:failed_terminal` if its attempt budget is exhausted.
    * a result with no matching admitted job is terminated as a dead letter without updating a job.
    * any other failure, including a raise: the message fails with
      `ServiceRadar.EventWriter.TransientMessageError`, which NAKs it with
      backoff.

  The batch size and the durable's `max_ack_pending`
  (`ServiceRadar.EventWriter.Config.camera_visual_index_results_stream/0`)
  bound the results in flight.
  """

  @behaviour ServiceRadar.EventWriter.Processor

  alias Broadway.Message
  alias ServiceRadar.Camera.VisualIndexResultProjector
  alias ServiceRadar.EventWriter.TerminalMessageError
  alias ServiceRadar.EventWriter.TransientMessageError

  @impl true
  def table_name, do: "camera_visual_embeddings"

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
    case VisualIndexResultProjector.ingest_result(data) do
      {:ok, %{embedding_count: count}} -> {:ok, count}
      {:error, :recording_gone} -> {:ok, 0}
      {:error, reason} -> classify_error(reason)
    end
  rescue
    error -> {:error, %TransientMessageError{reason: error}}
  end

  defp classify_error(reason) do
    if VisualIndexResultProjector.terminal_drop?(reason),
      do: {:error, %TerminalMessageError{reason: reason}},
      else: {:error, %TransientMessageError{reason: reason}}
  end
end
