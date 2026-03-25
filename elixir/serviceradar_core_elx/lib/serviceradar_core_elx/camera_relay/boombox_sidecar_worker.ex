defmodule ServiceRadarCoreElx.CameraRelay.BoomboxSidecarWorker do
  @moduledoc """
  Relay-attached reference sidecar that consumes Boombox branch output from a
  bounded local capture file and returns deterministic findings through the
  existing analysis result path.
  """

  use GenServer

  alias Boombox.Packet
  alias ServiceRadar.Camera.AnalysisResultIngestor
  alias ServiceRadar.Telemetry
  alias ServiceRadarCoreElx.CameraRelay.AnalysisBranchManager
  alias ServiceRadarCoreElx.CameraRelay.BoomboxHelpers
  alias Vix.Vips.Image, as: VipsImage

  @default_capture_ms 250
  @default_max_read_bytes 65_536
  @default_worker_id "boombox-sidecar-worker"

  def child_spec(opts) do
    %{
      id: {__MODULE__, {Map.get(opts, :relay_session_id), Map.get(opts, :branch_id)}},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    }
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def close(pid) when is_pid(pid) do
    GenServer.call(pid, :close, 15_000)
  end

  @impl true
  def init(opts) do
    relay_session_id = required_string!(opts, :relay_session_id)
    branch_id = required_string!(opts, :branch_id)
    output_path = Map.get(opts, :output_path, default_output_path(relay_session_id, branch_id))

    state = %{
      relay_session_id: relay_session_id,
      branch_id: branch_id,
      worker_id: optional_string(opts, :worker_id) || @default_worker_id,
      camera_source_id: optional_string(opts, :camera_source_id),
      camera_device_uid: optional_string(opts, :camera_device_uid),
      stream_profile_id: optional_string(opts, :stream_profile_id),
      output_path: output_path,
      policy: %{sample_interval_ms: 0, max_queue_len: 4},
      capture_ms: positive_integer(Map.get(opts, :capture_ms), @default_capture_ms),
      max_read_bytes: positive_integer(Map.get(opts, :max_read_bytes), @default_max_read_bytes),
      result_ingestor: Map.get(opts, :result_ingestor, AnalysisResultIngestor),
      telemetry_module: Map.get(opts, :telemetry_module, Telemetry),
      capture_timer_ref: nil,
      captured_input: nil,
      finalized?: false
    }

    case AnalysisBranchManager.open_branch(%{
           relay_session_id: relay_session_id,
           branch_id: branch_id,
           subscriber: self(),
           policy: state.policy
         }) do
      {:ok, _branch} ->
        timer_ref =
          if state.capture_ms > 0 do
            Process.send_after(self(), :capture_timeout, state.capture_ms)
          end

        {:ok, %{state | capture_timer_ref: timer_ref}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_info({:camera_analysis_input, input}, %{captured_input: nil} = state) do
    next_state =
      if captureable_input?(input) do
        File.write!(state.output_path, Map.get(input, :payload, <<>>), [:binary])
        %{state | captured_input: input}
      else
        state
      end

    {:noreply, next_state}
  end

  @impl true
  def handle_info(:capture_timeout, state) do
    {_reply, next_state} = finalize(state, "capture_timeout")
    {:stop, :normal, next_state}
  end

  def handle_info({:camera_analysis_input, _input}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_call(:close, _from, state) do
    {reply, next_state} = finalize(state, "requested_close")
    {:stop, :normal, reply, next_state}
  end

  @impl true
  def terminate(_reason, state) do
    cancel_timer(state.capture_timer_ref)

    if not state.finalized? do
      _ = AnalysisBranchManager.close_branch(state.relay_session_id, state.branch_id)
      cleanup_output(state.output_path)
    end

    :ok
  end

  defp finalize(%{finalized?: true} = state, _reason), do: {:ok, state}

  defp finalize(state, close_reason) do
    cancel_timer(state.capture_timer_ref)
    _ = AnalysisBranchManager.close_branch(state.relay_session_id, state.branch_id)

    reply =
      case build_result(state, close_reason) do
        [] ->
          :ok

        result ->
          emit_dispatch_event(state, :dispatch_succeeded)
          state.result_ingestor.ingest(result)
      end

    if match?({:error, _}, reply) do
      emit_dispatch_event(state, :dispatch_failed, reason: BoomboxHelpers.format_reason(elem(reply, 1)))
    end

    cleanup_output(state.output_path)
    {reply, %{state | finalized?: true, capture_timer_ref: nil}}
  end

  defp build_result(%{captured_input: nil}, _close_reason), do: []

  defp build_result(state, close_reason) do
    with {:ok, image_metadata} <- decode_capture_with_boombox(state.output_path),
         {:ok, binary} <- read_capture_file(state.output_path, state.max_read_bytes) do
      input = state.captured_input

      %{
        "schema" => "camera_analysis_result.v1",
        "relay_session_id" => state.relay_session_id,
        "branch_id" => state.branch_id,
        "worker_id" => state.worker_id,
        "camera_source_id" => state.camera_source_id,
        "camera_device_uid" => state.camera_device_uid,
        "stream_profile_id" => state.stream_profile_id,
        "media_ingest_id" => Map.get(input, :media_ingest_id),
        "sequence" => Map.get(input, :sequence),
        "detection" => %{
          "kind" => "boombox_capture_summary",
          "label" => "h264_annexb_capture",
          "confidence" => 1.0,
          "attributes" => %{
            "capture_bytes" => byte_size(binary),
            "start_code_count" => count_annexb_start_codes(binary),
            "close_reason" => close_reason,
            "boombox_frame_width" => image_metadata.width,
            "boombox_frame_height" => image_metadata.height
          }
        },
        "metadata" => %{
          "analysis_adapter" => "boombox",
          "analysis_mode" => "boombox_sidecar",
          "capture_bytes" => byte_size(binary),
          "start_code_count" => count_annexb_start_codes(binary),
          "close_reason" => close_reason,
          "boombox_frame_width" => image_metadata.width,
          "boombox_frame_height" => image_metadata.height
        }
      }
    else
      _ -> []
    end
  end

  defp decode_capture_with_boombox(path) do
    with {:ok, reader} <- BoomboxHelpers.start_reader(path) do
      try do
        case Boombox.read(reader) do
          {:ok, %Packet{payload: %VipsImage{} = image}} ->
            {:ok, %{width: VipsImage.width(image), height: VipsImage.height(image)}}

          {:ok, %Packet{payload: payload}} when is_map(payload) ->
            {:ok, %{width: map_size(payload), height: 0}}

          {:ok, _packet} ->
            {:ok, %{width: 0, height: 0}}

          :finished ->
            {:error, :no_packet}

          {:error, reason} ->
            {:error, reason}
        end
      catch
        :exit, reason -> {:error, {:boombox_read_failed, BoomboxHelpers.format_reason(reason)}}
      after
        _ = Boombox.close(reader)
      end
    end
  end

  defp read_capture_file(path, max_read_bytes) do
    case File.read(path) do
      {:ok, binary} when is_binary(binary) and byte_size(binary) > 0 ->
        {:ok, binary_part(binary, 0, min(byte_size(binary), max_read_bytes))}

      {:ok, _binary} ->
        {:error, :empty_capture}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp cleanup_output(path) do
    if is_binary(path), do: File.rm(path)
    :ok
  end

  defp cancel_timer(nil), do: :ok

  defp cancel_timer(ref) do
    _ = Process.cancel_timer(ref)
    :ok
  end

  defp count_annexb_start_codes(binary) when is_binary(binary) do
    do_count_start_codes(binary, 0)
  end

  defp do_count_start_codes(<<0, 0, 0, 1, rest::binary>>, count), do: do_count_start_codes(rest, count + 1)
  defp do_count_start_codes(<<_byte, rest::binary>>, count), do: do_count_start_codes(rest, count)
  defp do_count_start_codes(<<>>, count), do: count

  defp default_output_path(relay_session_id, branch_id) do
    filename = "serviceradar-boombox-sidecar-#{relay_session_id}-#{branch_id}-#{System.unique_integer([:positive])}.h264"
    Path.join(System.tmp_dir!(), filename)
  end

  defp required_string!(opts, key) do
    case opts |> Map.get(key, Map.get(opts, to_string(key), "")) |> to_string() |> String.trim() do
      "" -> raise ArgumentError, "#{key} is required"
      value -> value
    end
  end

  defp optional_string(opts, key) do
    case opts |> Map.get(key, Map.get(opts, to_string(key), "")) |> to_string() |> String.trim() do
      "" -> nil
      value -> value
    end
  end

  defp positive_integer(value, _default) when is_integer(value) and value > 0, do: value

  defp positive_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> default
    end
  end

  defp positive_integer(_value, default), do: default

  defp captureable_input?(input) when is_map(input) do
    Map.get(input, :keyframe, false) == true and is_binary(Map.get(input, :payload)) and
      byte_size(Map.get(input, :payload)) > 0
  end

  defp captureable_input?(_input), do: false

  defp emit_dispatch_event(state, event, attrs \\ []) do
    state.telemetry_module.emit_camera_relay_analysis_event(
      event,
      %{
        relay_boundary: "core_elx",
        relay_session_id: state.relay_session_id,
        branch_id: state.branch_id,
        worker_id: state.worker_id,
        adapter: "boombox",
        reason: attrs[:reason]
      },
      %{
        result_count: if(event == :dispatch_succeeded, do: 1, else: 0),
        sequence: extract_sequence(state.captured_input),
        timeout_ms: state.capture_ms
      }
    )
  end

  defp extract_sequence(nil), do: 0
  defp extract_sequence(input), do: Map.get(input, :sequence, 0)
end
