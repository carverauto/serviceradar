defmodule ServiceRadar.Camera.AnalysisContract do
  @moduledoc """
  Shared contract helpers for relay-scoped camera analysis input and result payloads.
  """

  @input_schema "camera_analysis_input.v1"
  @result_schema "camera_analysis_result.v1"

  def input_schema, do: @input_schema
  def result_schema, do: @result_schema

  def build_input(sample) when is_map(sample) do
    %{
      schema: @input_schema,
      relay_session_id: required_string!(sample, :relay_session_id),
      branch_id: required_string!(sample, :branch_id),
      media_ingest_id: optional_string(sample, :media_ingest_id),
      sequence: normalize_non_negative_integer(Map.get(sample, :sequence)),
      pts: normalize_non_negative_integer(Map.get(sample, :pts)),
      dts: normalize_non_negative_integer(Map.get(sample, :dts)),
      codec: optional_string(sample, :codec),
      payload_format: optional_string(sample, :payload_format),
      track_id: optional_string(sample, :track_id),
      keyframe: Map.get(sample, :keyframe, false) == true,
      payload: Map.get(sample, :payload, <<>>),
      policy: normalize_policy(Map.get(sample, :policy, %{}))
    }
  end

  def normalize_result(result) when is_map(result) do
    %{
      schema: optional_string(result, :schema) || @result_schema,
      relay_session_id: required_string!(result, :relay_session_id),
      branch_id: required_string!(result, :branch_id),
      worker_id: required_string!(result, :worker_id),
      camera_source_id: optional_string(result, :camera_source_id),
      camera_device_uid: optional_string(result, :camera_device_uid),
      stream_profile_id: optional_string(result, :stream_profile_id),
      media_ingest_id: optional_string(result, :media_ingest_id),
      sequence: normalize_non_negative_integer(value(result, :sequence)),
      observed_at: value(result, :observed_at),
      detection:
        normalize_detection(Map.get(result, :detection) || Map.get(result, "detection") || %{}),
      metadata: normalize_map(Map.get(result, :metadata) || Map.get(result, "metadata") || %{}),
      raw_result: result
    }
  end

  defp normalize_detection(detection) when is_map(detection) do
    %{
      kind: optional_string(detection, :kind) || "derived_finding",
      label: optional_string(detection, :label) || "detection",
      confidence:
        normalize_number(Map.get(detection, :confidence) || Map.get(detection, "confidence")),
      bbox: normalize_map(Map.get(detection, :bbox) || Map.get(detection, "bbox") || %{}),
      attributes:
        normalize_map(Map.get(detection, :attributes) || Map.get(detection, "attributes") || %{})
    }
  end

  defp normalize_detection(_),
    do: %{
      kind: "derived_finding",
      label: "detection",
      confidence: nil,
      bbox: %{},
      attributes: %{}
    }

  defp normalize_policy(policy) when is_map(policy) do
    %{
      sample_interval_ms:
        policy
        |> Map.get(:sample_interval_ms, Map.get(policy, "sample_interval_ms", 0))
        |> normalize_non_negative_integer(),
      max_queue_len:
        policy
        |> Map.get(:max_queue_len, Map.get(policy, "max_queue_len", 0))
        |> normalize_non_negative_integer()
    }
  end

  defp normalize_policy(_policy), do: %{sample_interval_ms: 0, max_queue_len: 0}

  defp normalize_map(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, map_value}, acc ->
      Map.put(acc, to_string(key), map_value)
    end)
  end

  defp normalize_map(_), do: %{}

  defp optional_string(map, key) when is_map(map) do
    map
    |> value(key, "")
    |> to_string()
    |> String.trim()
    |> case do
      "" -> nil
      value -> value
    end
  end

  defp required_string!(map, key) do
    case optional_string(map, key) do
      nil -> raise ArgumentError, "#{key} is required"
      value -> value
    end
  end

  defp normalize_non_negative_integer(value) when is_integer(value) and value >= 0, do: value

  defp normalize_non_negative_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed >= 0 -> parsed
      _ -> 0
    end
  end

  defp normalize_non_negative_integer(_), do: 0

  defp normalize_number(value) when is_integer(value), do: value / 1
  defp normalize_number(value) when is_float(value), do: value

  defp normalize_number(value) when is_binary(value) do
    case Float.parse(value) do
      {parsed, _} -> parsed
      :error -> nil
    end
  end

  defp normalize_number(_), do: nil

  defp value(map, key, default \\ nil) when is_map(map) do
    Map.get(map, key, Map.get(map, to_string(key), default))
  end
end
