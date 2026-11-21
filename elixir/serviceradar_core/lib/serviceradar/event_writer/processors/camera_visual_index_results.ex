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

    fail_job = Keyword.get(opts, :fail_job, &VisualIndexDispatcher.reconcile_exhausted_job/2)

    {stored, failures} =
      Enum.reduce(messages, {0, []}, fn message, {stored, failures} ->
        case store(message, ingest, fail_job) do
          :ok -> {stored + 1, failures}
          {:error, error} -> {stored, [{message, error} | failures]}
        end
      end)

    case failures do
      [] -> {:ok, stored}
      _ -> {:incomplete, stored, Enum.reverse(failures)}
    end
  end

  defp store(%Message{data: data}, ingest, fail_job) do
    case VisualIndexResultProjector.decode_result(data) do
      {:ok, envelope} -> project(envelope, ingest, fail_job)
      {:error, reason, job_id} -> terminate(job_id, reason, fail_job)
    end
  rescue
    error -> {:error, %TransientMessageError{reason: error}}
  end

  defp project(envelope, ingest, fail_job) do
    case ingest.(envelope) do
      {:ok, _projection} ->
        :ok

      {:error, :recording_gone} ->
        :ok

      {:error, reason} ->
        if VisualIndexResultProjector.terminal_drop?(reason),
          do: terminate(envelope["job_id"], reason, fail_job),
          else: {:error, %TransientMessageError{reason: reason}}
    end
  end

  defp terminate(job_id, reason, fail_job) when is_binary(job_id) do
    case fail_job.(job_id, Atom.to_string(reason)) do
      {:ok, _job} ->
        {:error, %TerminalMessageError{reason: reason}}

      {:error, unknown} when unknown in [:job_not_found, :invalid_job_id] ->
        {:error, %TerminalMessageError{reason: reason}}

      {:error, error} ->
        {:error, %TransientMessageError{reason: error}}
    end
  end

  defp terminate(_job_id, reason, _fail_job), do: {:error, %TerminalMessageError{reason: reason}}
end
