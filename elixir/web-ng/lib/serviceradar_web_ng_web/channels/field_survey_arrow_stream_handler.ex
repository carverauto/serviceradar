defmodule ServiceRadarWebNGWeb.Channels.FieldSurveyArrowStreamHandler do
  @moduledoc """
  WebSock handler for FieldSurvey raw RF and pose Arrow IPC ingest streams.
  """
  @behaviour WebSock

  alias ServiceRadar.Repo
  alias ServiceRadarWebNG.FieldSurveyStreamLimiter
  alias ServiceRadarWebNG.Topology.Native

  require Logger

  @max_frame_size 8 * 1024 * 1024

  @impl true
  def init(options) do
    session_id = Keyword.fetch!(options, :session_id)
    user_id = Keyword.fetch!(options, :user_id)
    stream_type = Keyword.fetch!(options, :stream_type)

    state =
      %{
        session_id: session_id,
        user_id: user_id,
        stream_type: stream_type,
        limiter_token: nil,
        acquire_stream: Keyword.get(options, :acquire_stream, &FieldSurveyStreamLimiter.acquire/2),
        release_stream: Keyword.get(options, :release_stream, &FieldSurveyStreamLimiter.release/1),
        decode_rf_payload: Keyword.get(options, :decode_rf_payload, &decode_rf_payload/1),
        decode_pose_payload: Keyword.get(options, :decode_pose_payload, &decode_pose_payload/1),
        decode_spectrum_payload: Keyword.get(options, :decode_spectrum_payload, &decode_spectrum_payload/1),
        bulk_insert_rf: Keyword.get(options, :bulk_insert_rf, &bulk_insert_rf/2),
        bulk_insert_pose: Keyword.get(options, :bulk_insert_pose, &bulk_insert_pose/2),
        bulk_insert_spectrum: Keyword.get(options, :bulk_insert_spectrum, &bulk_insert_spectrum/2),
        archive_frame: Keyword.get(options, :archive_frame, &archive_frame/2),
        message_count: 0,
        bytes_received: 0,
        rows_received: 0,
        frames_archived: 0
      }

    case state.acquire_stream.(to_string(user_id), session_id) do
      {:ok, limiter_token} ->
        Logger.info("FieldSurvey #{stream_type} stream initialized [session: #{session_id}, user: #{user_id}]")
        {:ok, %{state | limiter_token: limiter_token}}

      {:error, reason} ->
        Logger.warning(
          "Rejecting FieldSurvey #{stream_type} stream [session: #{session_id}, user: #{user_id}, reason: #{inspect(reason)}]"
        )

        {:stop, :normal, {1013, "too many FieldSurvey streams"}, state}
    end
  end

  @impl true
  def handle_in({data, [opcode: :binary]}, state) when byte_size(data) > @max_frame_size do
    Logger.warning(
      "FieldSurvey #{state.stream_type} frame too large [session: #{state.session_id}, bytes: #{byte_size(data)}]"
    )

    {:stop, :normal, {1009, "FieldSurvey frame too large"}, state}
  end

  def handle_in({data, [opcode: :binary]}, state) do
    new_state = %{
      state
      | message_count: state.message_count + 1,
        bytes_received: state.bytes_received + byte_size(data)
    }

    case ingest_frame(data, new_state) do
      {:ok, row_count} ->
        archived_state = archive_ingested_frame(data, row_count, :ok, nil, new_state)
        {:ok, %{archived_state | rows_received: archived_state.rows_received + row_count}}

      {:error, reason} ->
        archived_state = archive_ingested_frame(data, 0, :error, inspect(reason), new_state)
        log_ingest_error(reason, archived_state)
    end
  end

  @impl true
  def handle_in({data, [opcode: :text]}, state) do
    Logger.warning("Received unexpected FieldSurvey #{state.stream_type} text payload (size: #{byte_size(data)})")

    {:ok, state}
  end

  @impl true
  def handle_info(message, state) do
    Logger.debug("FieldSurvey stream handler received internal message: #{inspect(message)}")
    {:ok, state}
  end

  @impl true
  def terminate(reason, state) do
    state.release_stream.(state.limiter_token)

    Logger.info(
      "FieldSurvey #{state.stream_type} stream closed [session: #{state.session_id}, reason: #{inspect(reason)}, msgs: #{state.message_count}, bytes: #{state.bytes_received}, rows: #{state.rows_received}, archived_frames: #{state.frames_archived}]"
    )

    :ok
  end

  defp archive_ingested_frame(data, row_count, decode_status, decode_error, state) do
    metadata = %{
      session_id: state.session_id,
      user_id: state.user_id,
      stream_type: state.stream_type,
      frame_index: state.message_count,
      byte_size: byte_size(data),
      row_count: row_count,
      decode_status: decode_status,
      decode_error: decode_error
    }

    if state.archive_frame.(data, metadata) do
      %{state | frames_archived: state.frames_archived + 1}
    else
      Logger.warning(
        "FieldSurvey #{state.stream_type} Arrow IPC frame archive failed [session: #{state.session_id}, frame: #{state.message_count}]"
      )

      state
    end
  rescue
    error ->
      Logger.warning(
        "FieldSurvey #{state.stream_type} Arrow IPC frame archive raised [session: #{state.session_id}, frame: #{state.message_count}]: #{inspect(error)}"
      )

      state
  end

  defp ingest_frame(data, %{stream_type: :rf_observations, session_id: session_id} = state) do
    case state.decode_rf_payload.(data) do
      {:ok, observations} ->
        if state.bulk_insert_rf.(session_id, observations) do
          {:ok, length(observations)}
        else
          {:error, :rf_insert_failed}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ingest_frame(data, %{stream_type: :pose_samples, session_id: session_id} = state) do
    case state.decode_pose_payload.(data) do
      {:ok, samples} ->
        if state.bulk_insert_pose.(session_id, samples) do
          {:ok, length(samples)}
        else
          {:error, :pose_insert_failed}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ingest_frame(data, %{stream_type: :spectrum_observations, session_id: session_id} = state) do
    case state.decode_spectrum_payload.(data) do
      {:ok, observations} ->
        if state.bulk_insert_spectrum.(session_id, observations) do
          {:ok, length(observations)}
        else
          {:error, :spectrum_insert_failed}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decode_rf_payload(data) do
    case Native.decode_fieldsurvey_rf_payload(data) do
      {:ok, observations} when is_list(observations) -> {:ok, observations}
      observations when is_list(observations) -> {:ok, observations}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_decoder_result, other}}
    end
  rescue
    error -> {:error, error}
  end

  defp decode_pose_payload(data) do
    case Native.decode_fieldsurvey_pose_payload(data) do
      {:ok, samples} when is_list(samples) -> {:ok, samples}
      samples when is_list(samples) -> {:ok, samples}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_decoder_result, other}}
    end
  rescue
    error -> {:error, error}
  end

  defp decode_spectrum_payload(data) do
    case Native.decode_fieldsurvey_spectrum_payload(data) do
      {:ok, observations} when is_list(observations) -> {:ok, observations}
      observations when is_list(observations) -> {:ok, observations}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_decoder_result, other}}
    end
  rescue
    error -> {:error, error}
  end

  defp bulk_insert_rf(_session_id, []), do: true

  defp bulk_insert_rf(session_id, observations) do
    ServiceRadar.Spatial.SurveyRfObservation
    |> Ash.ActionInput.for_action(:bulk_insert, %{
      session_id: session_id,
      observations: observations
    })
    |> Ash.run_action!(domain: ServiceRadar.Spatial)
  end

  defp bulk_insert_pose(_session_id, []), do: true

  defp bulk_insert_pose(session_id, samples) do
    ServiceRadar.Spatial.SurveyPoseSample
    |> Ash.ActionInput.for_action(:bulk_insert, %{
      session_id: session_id,
      samples: samples
    })
    |> Ash.run_action!(domain: ServiceRadar.Spatial)
  end

  defp bulk_insert_spectrum(_session_id, []), do: true

  defp bulk_insert_spectrum(session_id, observations) do
    ServiceRadar.Spatial.SurveySpectrumObservation
    |> Ash.ActionInput.for_action(:bulk_insert, %{
      session_id: session_id,
      observations: observations
    })
    |> Ash.run_action!(domain: ServiceRadar.Spatial)
  end

  defp archive_frame(data, metadata) do
    now = DateTime.utc_now()

    entry = %{
      session_id: metadata.session_id,
      user_id: to_string(metadata.user_id),
      stream_type: Atom.to_string(metadata.stream_type),
      frame_index: metadata.frame_index,
      byte_size: metadata.byte_size,
      row_count: metadata.row_count,
      decode_status: Atom.to_string(metadata.decode_status),
      decode_error: truncate_error(metadata.decode_error),
      payload_sha256: :crypto.hash(:sha256, data),
      payload: data,
      received_at: now,
      inserted_at: now
    }

    case Repo.insert_all("survey_arrow_ipc_frames", [entry], prefix: "platform") do
      {1, _} -> true
      _ -> false
    end
  end

  defp truncate_error(nil), do: nil
  defp truncate_error(error) when byte_size(error) <= 2_000, do: error
  defp truncate_error(error), do: binary_part(error, 0, 2_000)

  defp log_ingest_error(reason, state) do
    Logger.error(
      "FieldSurvey #{state.stream_type} Arrow IPC ingest failed [session: #{state.session_id}]: #{inspect(reason)}"
    )

    {:ok, state}
  end
end
