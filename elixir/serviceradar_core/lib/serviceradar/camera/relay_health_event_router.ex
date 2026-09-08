defmodule ServiceRadar.Camera.RelayHealthEventRouter do
  @moduledoc """
  Records camera relay health signals as OCSF events so the standard
  observability and alerting path can evaluate bursty relay degradation.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Events.PubSub, as: EventsPubSub
  alias ServiceRadar.Monitoring.OcsfEvent

  @provider "serviceradar.relay_health_event_router"

  @session_failure_log_name "camera.relay.session.failed"
  @gateway_saturation_log_name "camera.relay.gateway.saturation_denied"
  @viewer_idle_log_name "camera.relay.session.viewer_idle"

  @failure_burst_alert_log_name "camera.relay.alert.failure_burst"
  @gateway_saturation_alert_log_name "camera.relay.alert.gateway_saturation"
  @viewer_idle_churn_alert_log_name "camera.relay.alert.viewer_idle_churn"

  @default_class_uid 1008
  @default_category_uid 1
  @default_activity_id 1
  @default_type_uid 100_801
  @default_status_id 1

  @spec session_failure_log_name() :: String.t()
  def session_failure_log_name, do: @session_failure_log_name

  @spec gateway_saturation_log_name() :: String.t()
  def gateway_saturation_log_name, do: @gateway_saturation_log_name

  @spec viewer_idle_log_name() :: String.t()
  def viewer_idle_log_name, do: @viewer_idle_log_name

  @spec failure_burst_alert_log_name() :: String.t()
  def failure_burst_alert_log_name, do: @failure_burst_alert_log_name

  @spec gateway_saturation_alert_log_name() :: String.t()
  def gateway_saturation_alert_log_name, do: @gateway_saturation_alert_log_name

  @spec viewer_idle_churn_alert_log_name() :: String.t()
  def viewer_idle_churn_alert_log_name, do: @viewer_idle_churn_alert_log_name

  @spec relay_health_log_names() :: [String.t()]
  def relay_health_log_names do
    [
      @session_failure_log_name,
      @gateway_saturation_log_name,
      @viewer_idle_log_name
    ]
  end

  @spec relay_health_alert_log_names() :: [String.t()]
  def relay_health_alert_log_names do
    [
      @failure_burst_alert_log_name,
      @gateway_saturation_alert_log_name,
      @viewer_idle_churn_alert_log_name
    ]
  end

  @spec record_session_failure(map(), keyword()) :: :ok | {:error, term()}
  def record_session_failure(context, opts \\ []) when is_map(context) do
    record(:session_failure, context, opts)
  end

  @spec record_gateway_saturation_denial(map(), keyword()) :: :ok | {:error, term()}
  def record_gateway_saturation_denial(context, opts \\ []) when is_map(context) do
    record(:gateway_saturation_denial, context, opts)
  end

  @spec record_viewer_idle_termination(map(), keyword()) :: :ok | {:error, term()}
  def record_viewer_idle_termination(context, opts \\ []) when is_map(context) do
    record(:viewer_idle_termination, context, opts)
  end

  defp record(kind, context, opts) do
    actor = Keyword.get(opts, :actor, SystemActor.system(:camera_relay_health_event_router))
    record_event = Keyword.get(opts, :record_event, &record_event/2)
    broadcast_event = Keyword.get(opts, :broadcast_event, &EventsPubSub.broadcast_event/1)

    attrs = build_event_attrs(kind, context)

    try do
      with {:ok, event} <- record_event.(attrs, actor) do
        broadcast_event.(event)
      end
    rescue
      error ->
        {:error, error}
    end
  end

  defp build_event_attrs(kind, context) do
    {severity_id, severity, log_level} = severity_for_kind(kind)
    metadata = event_metadata(kind, context)
    status_detail = status_detail(kind, metadata)

    %{
      time: DateTime.truncate(DateTime.utc_now(), :microsecond),
      class_uid: @default_class_uid,
      category_uid: @default_category_uid,
      type_uid: @default_type_uid,
      activity_id: @default_activity_id,
      activity_name: "Relay Health",
      severity_id: severity_id,
      severity: severity,
      message: event_message(kind, metadata),
      status_id: @default_status_id,
      status: status_name(kind),
      status_code: status_code(kind),
      status_detail: status_detail,
      metadata: metadata,
      observables: event_observables(metadata),
      actor: %{
        "app_name" => "serviceradar.core",
        "process" => "camera_relay_health_event_router",
        "relay_boundary" => Map.get(metadata, "relay_boundary")
      },
      device: %{},
      src_endpoint: %{},
      dst_endpoint: %{},
      log_name: log_name(kind),
      log_provider: @provider,
      log_level: log_level,
      log_version: "camera_relay_health.v1",
      unmapped: %{
        "relay_health" => metadata
      },
      raw_data: Jason.encode!(metadata)
    }
  end

  defp event_metadata(kind, context) do
    %{
      "relay_health_kind" => relay_health_kind(kind),
      "relay_boundary" => map_value(context, :relay_boundary),
      "relay_session_id" => map_value(context, :relay_session_id),
      "media_ingest_id" => map_value(context, :media_ingest_id),
      "agent_id" => map_value(context, :agent_id),
      "gateway_id" => map_value(context, :gateway_id),
      "partition_id" => map_value(context, :partition_id),
      "camera_source_id" => map_value(context, :camera_source_id),
      "stream_profile_id" => map_value(context, :stream_profile_id),
      "relay_status" => map_value(context, :relay_status),
      "playback_state" => map_value(context, :playback_state),
      "termination_kind" => map_value(context, :termination_kind),
      "close_reason" => map_value(context, :close_reason),
      "failure_reason" => map_value(context, :failure_reason),
      "viewer_count" => map_value(context, :viewer_count),
      "stage" => map_value(context, :stage),
      "reason" => map_value(context, :reason),
      "limit_kind" => map_value(context, :limit_kind),
      "limit" => map_value(context, :limit)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp status_detail(:session_failure, metadata) do
    Map.get(metadata, "failure_reason") || Map.get(metadata, "reason") || "relay_session_failed"
  end

  defp status_detail(:gateway_saturation_denial, metadata) do
    Map.get(metadata, "reason") ||
      case {Map.get(metadata, "gateway_id"), Map.get(metadata, "limit_kind")} do
        {gateway_id, limit_kind} when is_binary(gateway_id) and is_binary(limit_kind) ->
          "gateway #{gateway_id} #{limit_kind} saturation denial"

        _other ->
          "gateway saturation denial"
      end
  end

  defp status_detail(:viewer_idle_termination, metadata) do
    Map.get(metadata, "close_reason") || "viewer idle timeout"
  end

  defp event_message(:session_failure, metadata) do
    stage = Map.get(metadata, "stage") || "runtime"
    reason = Map.get(metadata, "failure_reason") || Map.get(metadata, "reason") || "unknown"
    "Camera relay session failed during #{stage}: #{reason}"
  end

  defp event_message(:gateway_saturation_denial, metadata) do
    gateway_id = Map.get(metadata, "gateway_id") || "unknown-gateway"
    limit_kind = Map.get(metadata, "limit_kind") || "gateway"
    limit = Map.get(metadata, "limit")

    if is_integer(limit) do
      "Camera relay denied on #{gateway_id}: #{limit_kind} saturation limit #{limit}"
    else
      "Camera relay denied on #{gateway_id}: #{limit_kind} saturation"
    end
  end

  defp event_message(:viewer_idle_termination, metadata) do
    relay_session_id = Map.get(metadata, "relay_session_id") || "unknown-relay"
    "Camera relay #{relay_session_id} closed due to viewer idle timeout"
  end

  defp event_observables(metadata) do
    Enum.reject(
      [
        observable(Map.get(metadata, "relay_session_id"), "Relay Session ID"),
        observable(Map.get(metadata, "gateway_id"), "Gateway ID"),
        observable(Map.get(metadata, "camera_source_id"), "Camera Source ID"),
        observable(Map.get(metadata, "relay_health_kind"), "Relay Health Kind")
      ],
      &is_nil/1
    )
  end

  defp observable(nil, _name), do: nil
  defp observable("", _name), do: nil

  defp observable(value, name) do
    %{"name" => name, "type" => "string", "value" => value}
  end

  defp record_event(attrs, actor) do
    Ash.create(OcsfEvent, attrs,
      action: :record,
      actor: actor,
      domain: ServiceRadar.Monitoring
    )
  end

  defp log_name(:session_failure), do: @session_failure_log_name
  defp log_name(:gateway_saturation_denial), do: @gateway_saturation_log_name
  defp log_name(:viewer_idle_termination), do: @viewer_idle_log_name

  defp status_name(:viewer_idle_termination), do: "Success"
  defp status_name(_kind), do: "Failure"

  defp status_code(:session_failure), do: "camera_relay_session_failed"
  defp status_code(:gateway_saturation_denial), do: "camera_relay_gateway_saturation_denied"
  defp status_code(:viewer_idle_termination), do: "camera_relay_viewer_idle_termination"

  defp relay_health_kind(:session_failure), do: "session_failure"
  defp relay_health_kind(:gateway_saturation_denial), do: "gateway_saturation_denial"
  defp relay_health_kind(:viewer_idle_termination), do: "viewer_idle_termination"

  defp severity_for_kind(:session_failure), do: {4, "High", "error"}
  defp severity_for_kind(:gateway_saturation_denial), do: {3, "Medium", "warning"}
  defp severity_for_kind(:viewer_idle_termination), do: {2, "Low", "info"}

  defp map_value(map, key, default \\ nil)

  defp map_value(map, key, default) when is_map(map) do
    Map.get(map, key, Map.get(map, to_string(key), default))
  end
end
