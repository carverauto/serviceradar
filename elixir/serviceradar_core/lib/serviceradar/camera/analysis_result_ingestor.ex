defmodule ServiceRadar.Camera.AnalysisResultIngestor do
  @moduledoc """
  Normalizes camera analysis results into OCSF event surfaces with relay provenance.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Camera.AnalysisContract
  alias ServiceRadar.Events.PubSub, as: EventsPubSub
  alias ServiceRadar.Monitoring.OcsfEvent

  @default_class_uid 1008
  @default_category_uid 1
  @default_activity_id 1
  @default_type_uid 100_801
  @default_status_id 1
  @default_status "Success"
  @default_severity_id 2

  @spec ingest(map(), keyword()) :: :ok | {:error, term()}
  def ingest(result, opts \\ [])

  def ingest(result, opts) when is_map(result) do
    actor = Keyword.get(opts, :actor, SystemActor.system(:camera_analysis_result_ingestor))
    record_event = Keyword.get(opts, :record_event, &record_event/2)
    broadcast_event = Keyword.get(opts, :broadcast_event, &EventsPubSub.broadcast_event/1)
    normalized = AnalysisContract.normalize_result(result)
    attrs = build_event_attrs(normalized)

    case record_event.(attrs, actor) do
      {:ok, record} ->
        broadcast_event.(record)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  def ingest(_result, _opts), do: {:error, :invalid_payload}

  defp build_event_attrs(result) do
    observed_at = normalize_observed_at(result.observed_at)
    detection = result.detection
    severity_id = severity_id_for_confidence(detection.confidence)
    severity = severity_name(severity_id)
    message = "Camera analysis detection: #{detection.label}"

    %{
      id: Ash.UUID.generate(),
      time: observed_at,
      class_uid: @default_class_uid,
      category_uid: @default_category_uid,
      type_uid: @default_type_uid,
      activity_id: @default_activity_id,
      activity_name: "Create",
      severity_id: severity_id,
      severity: severity,
      message: message,
      status_id: @default_status_id,
      status: @default_status,
      status_code: "analysis_detection",
      status_detail: detection.kind,
      metadata:
        Map.merge(
          %{
            "relay_session_id" => result.relay_session_id,
            "analysis_branch_id" => result.branch_id,
            "analysis_worker_id" => result.worker_id,
            "camera_source_id" => result.camera_source_id,
            "camera_device_uid" => result.camera_device_uid,
            "stream_profile_id" => result.stream_profile_id,
            "media_ingest_id" => result.media_ingest_id,
            "sequence" => result.sequence,
            "analysis_schema" => result.schema,
            "detection_kind" => detection.kind,
            "detection_label" => detection.label,
            "detection_confidence" => detection.confidence
          },
          result.metadata
        ),
      observables: build_observables(result, detection),
      actor: %{
        "app_name" => "serviceradar.core",
        "process" => "camera_analysis_result_ingestor",
        "worker_id" => result.worker_id
      },
      device: build_device(result),
      src_endpoint: %{},
      dst_endpoint: %{},
      log_name: "camera.analysis.detection",
      log_provider: result.worker_id,
      log_level: severity_log_level(severity_id),
      log_version: result.schema,
      unmapped: %{
        "analysis_result" => result.raw_result,
        "detection" => %{
          "kind" => detection.kind,
          "label" => detection.label,
          "confidence" => detection.confidence,
          "bbox" => detection.bbox,
          "attributes" => detection.attributes
        }
      },
      raw_data: Jason.encode!(result.raw_result)
    }
  end

  defp build_observables(result, detection) do
    Enum.reject(
      [
        observable(result.relay_session_id, "Relay Session ID"),
        observable(result.branch_id, "Analysis Branch ID"),
        observable(result.camera_source_id, "Camera Source ID"),
        observable(detection.label, "Detection Label")
      ],
      &is_nil/1
    )
  end

  defp observable(nil, _type), do: nil
  defp observable("", _type), do: nil
  defp observable(value, type), do: %{"name" => type, "type" => "string", "value" => value}

  defp build_device(%{camera_device_uid: nil}), do: %{}

  defp build_device(result) do
    %{
      "uid" => result.camera_device_uid,
      "type" => "camera",
      "name" => result.camera_device_uid
    }
  end

  defp normalize_observed_at(%DateTime{} = observed_at),
    do: DateTime.truncate(observed_at, :microsecond)

  defp normalize_observed_at(_), do: DateTime.truncate(DateTime.utc_now(), :microsecond)

  defp severity_id_for_confidence(confidence)
       when is_float(confidence) or is_integer(confidence) do
    cond do
      confidence >= 0.9 -> 3
      confidence >= 0.5 -> 2
      true -> 1
    end
  end

  defp severity_id_for_confidence(_), do: @default_severity_id

  defp severity_name(3), do: "Medium"
  defp severity_name(2), do: "Low"
  defp severity_name(1), do: "Informational"
  defp severity_name(_), do: "Informational"

  defp severity_log_level(3), do: "warning"
  defp severity_log_level(2), do: "info"
  defp severity_log_level(1), do: "info"
  defp severity_log_level(_), do: "info"

  defp record_event(attrs, actor) do
    Ash.create(OcsfEvent, attrs, actor: actor, domain: ServiceRadar.Monitoring)
  end
end
