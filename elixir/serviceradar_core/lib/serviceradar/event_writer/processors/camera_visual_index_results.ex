defmodule ServiceRadar.EventWriter.Processors.CameraVisualIndexResults do
  @moduledoc """
  Stores media worker visual index results (`media.results.visual_index.v1`,
  on the worker-owned `CAMERA_MEDIA_RESULTS` stream) through
  `ServiceRadar.Camera.VisualIndexResultProjector`, the only writer of visual
  frames and embeddings.

  Each message is stored on its own, in its own transaction:

    * stored, or a replay of a stored result: acknowledged. The projector
      upserts by frame and region identity, so a replay changes nothing.
    * the recording was deleted or quarantined while the worker ran:
      acknowledged. The projector stores nothing and cancels the entry's jobs.
    * a result that can never be stored
      (`VisualIndexResultProjector.terminal_drop?/1`): the job it names is
      marked `:failed_terminal` with the failure class (and a `TripwireHealth`
      record), then the message fails with
      `ServiceRadar.EventWriter.TerminalMessageError`, which terminates it as a
      dead letter. If that job update fails, the message fails transiently so a
      later delivery records it.
    * any other failure, including a raise: the message fails with
      `ServiceRadar.EventWriter.TransientMessageError`, which NAKs it with
      backoff.

  The batch size and the durable's `max_ack_pending`
  (`ServiceRadar.EventWriter.Config.camera_visual_index_results_stream/0`)
  bound the results in flight.
  """

  @behaviour ServiceRadar.EventWriter.Processor

  alias Broadway.Message
  alias ServiceRadar.Camera.VisualIndexDispatcher
  alias ServiceRadar.Camera.VisualIndexResultProjector
  alias ServiceRadar.EventWriter.TerminalMessageError
  alias ServiceRadar.EventWriter.TransientMessageError

  @impl true
  def table_name, do: "camera_visual_embeddings"

  @impl true
  def process_batch(messages), do: process_batch(messages, [])

  @doc false
  # `:ingest` replaces `VisualIndexResultProjector.ingest_result/1` (tests).
  def process_batch(messages, opts) when is_list(messages) do
    ingest = Keyword.get(opts, :ingest, &VisualIndexResultProjector.ingest_result/1)

    {stored, failures} =
      Enum.reduce(messages, {0, []}, fn message, {stored, failures} ->
        case store(message, ingest) do
          :ok -> {stored + 1, failures}
          {:error, error} -> {stored, [{message, error} | failures]}
        end
      end)

    case failures do
      [] -> {:ok, stored}
      _ -> {:incomplete, stored, Enum.reverse(failures)}
    end
  end

  defp store(%Message{data: data}, ingest) do
    case ingest_isolated(ingest, data) do
      {:ok, _projection} ->
        :ok

      {:error, :recording_gone} ->
        :ok

      {:error, reason} ->
        if VisualIndexResultProjector.terminal_drop?(reason),
          do: terminate(data, reason),
          else: {:error, %TransientMessageError{reason: reason}}
    end
  end

  # One message's raise must not fail the rest of its batch.
  defp ingest_isolated(ingest, data) do
    ingest.(data)
  rescue
    error -> {:error, error}
  end

  defp terminate(data, reason) do
    terminal = {:error, %TerminalMessageError{reason: reason}}

    case result_job_id(data) do
      nil ->
        terminal

      job_id ->
        case VisualIndexDispatcher.reconcile_exhausted_job(job_id, Atom.to_string(reason)) do
          {:ok, _job} -> terminal
          {:error, unknown} when unknown in [:job_not_found, :invalid_job_id] -> terminal
          {:error, record_error} -> {:error, %TransientMessageError{reason: record_error}}
        end
    end
  end

  defp result_job_id(data) when is_binary(data) do
    case Jason.decode(data) do
      {:ok, %{"job_id" => job_id}} when is_binary(job_id) -> job_id
      _ -> nil
    end
  end

  defp result_job_id(_data), do: nil
end
