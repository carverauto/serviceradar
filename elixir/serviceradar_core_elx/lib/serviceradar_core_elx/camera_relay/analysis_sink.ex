defmodule ServiceRadarCoreElx.CameraRelay.AnalysisSink do
  @moduledoc """
  Membrane sink that emits bounded relay samples to analysis consumers.
  """

  use Membrane.Sink

  alias ServiceRadar.Camera.AnalysisContract
  alias ServiceRadar.Telemetry

  @default_policy %{sample_interval_ms: 0, max_queue_len: 32}

  def_options(
    relay_session_id: [
      spec: String.t(),
      description: "Relay session id for the attached analysis branch"
    ],
    branch_id: [
      spec: String.t(),
      description: "Analysis branch id within the relay session"
    ],
    subscriber: [
      spec: pid(),
      description: "Process that receives bounded analysis samples"
    ],
    policy: [
      spec: map(),
      default: @default_policy,
      description: "Bounded extraction policy"
    ],
    telemetry_module: [
      spec: module(),
      default: Telemetry,
      description: "Telemetry emitter for analysis sample events"
    ]
  )

  def_input_pad(:input,
    availability: :on_request,
    flow_control: :push,
    accepted_format: _any
  )

  @impl true
  def handle_init(_ctx, opts) do
    policy = normalize_policy(opts.policy)

    {[],
     %{
       relay_session_id: opts.relay_session_id,
       branch_id: opts.branch_id,
       subscriber: opts.subscriber,
       policy: policy,
       telemetry_module: opts.telemetry_module,
       last_emitted_pts: nil
     }}
  end

  @impl true
  def handle_buffer(_pad, buffer, _ctx, state) do
    metadata = Map.get(buffer, :metadata, %{})
    pts = normalize_timestamp(buffer.pts)
    payload_bytes = byte_size(buffer.payload)

    if emit_sample?(pts, state) do
      if subscriber_backed_up?(state) do
        emit_sample_event(state, :sample_dropped, metadata,
          reason: "backpressure",
          payload_bytes: payload_bytes,
          queue_length: subscriber_queue_len(state.subscriber)
        )

        {[], state}
      else
        send(
          state.subscriber,
          {:camera_analysis_input, AnalysisContract.build_input(build_sample(state, buffer, metadata, pts))}
        )

        emit_sample_event(state, :sample_emitted, metadata, payload_bytes: payload_bytes)

        {[], %{state | last_emitted_pts: pts || state.last_emitted_pts}}
      end
    else
      {[], state}
    end
  end

  defp build_sample(state, buffer, metadata, pts) do
    %{
      relay_session_id: state.relay_session_id,
      branch_id: state.branch_id,
      policy: state.policy,
      media_ingest_id: Map.get(metadata, :media_ingest_id),
      sequence: Map.get(metadata, :sequence),
      pts: pts,
      dts: normalize_timestamp(buffer.dts),
      codec: Map.get(metadata, :codec),
      payload_format: Map.get(metadata, :payload_format),
      track_id: Map.get(metadata, :track_id),
      keyframe: Map.get(metadata, :keyframe, false) == true,
      payload: buffer.payload
    }
  end

  defp emit_sample?(_pts, %{last_emitted_pts: nil}), do: true
  defp emit_sample?(nil, _state), do: false

  defp emit_sample?(pts, state) do
    interval_ns = state.policy.sample_interval_ms * 1_000_000
    interval_ns <= 0 or pts - state.last_emitted_pts >= interval_ns
  end

  defp normalize_policy(policy) when is_map(policy) do
    %{
      sample_interval_ms:
        policy
        |> Map.get(:sample_interval_ms, Map.get(policy, "sample_interval_ms", 0))
        |> normalize_non_negative_integer(),
      max_queue_len:
        policy
        |> Map.get(:max_queue_len, Map.get(policy, "max_queue_len", 32))
        |> normalize_positive_integer(32)
    }
  end

  defp normalize_policy(_policy), do: @default_policy

  defp normalize_non_negative_integer(value) when is_integer(value) and value >= 0, do: value

  defp normalize_non_negative_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed >= 0 -> parsed
      _ -> 0
    end
  end

  defp normalize_non_negative_integer(_value), do: 0

  defp normalize_positive_integer(value, _default) when is_integer(value) and value > 0, do: value

  defp normalize_positive_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> default
    end
  end

  defp normalize_positive_integer(_value, default), do: default

  defp normalize_timestamp(value) when is_integer(value), do: value
  defp normalize_timestamp(_value), do: nil

  defp subscriber_backed_up?(state) do
    subscriber_queue_len(state.subscriber) >= state.policy.max_queue_len
  end

  defp subscriber_queue_len(subscriber) when is_pid(subscriber) do
    case Process.info(subscriber, :message_queue_len) do
      {:message_queue_len, queue_len} when is_integer(queue_len) -> queue_len
      _ -> 0
    end
  end

  defp emit_sample_event(state, event, metadata, measurements) do
    state.telemetry_module.emit_camera_relay_analysis_event(
      event,
      %{
        relay_boundary: "core_elx",
        relay_session_id: state.relay_session_id,
        branch_id: state.branch_id,
        reason: measurements[:reason],
        codec: Map.get(metadata, :codec),
        payload_format: Map.get(metadata, :payload_format),
        track_id: Map.get(metadata, :track_id)
      },
      %{
        payload_bytes: measurements[:payload_bytes] || 0,
        queue_length: measurements[:queue_length] || 0,
        sample_interval_ms: state.policy.sample_interval_ms,
        max_queue_len: state.policy.max_queue_len
      }
    )
  end
end
