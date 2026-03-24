defmodule ServiceRadar.Camera.AnalysisWorkerAlertRouter do
  @moduledoc """
  Routes camera analysis worker alert transitions into the standard OCSF event
  and alert model without creating a parallel alerting subsystem.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Events.PubSub, as: EventsPubSub
  alias ServiceRadar.Monitoring.Alert
  alias ServiceRadar.Monitoring.OcsfEvent

  require Ash.Query

  @activation_log_name "camera.analysis.worker.alert"
  @clear_log_name "camera.analysis.worker.alert.clear"
  @provider "serviceradar.analysis_worker_alert_router"

  @default_class_uid 1008
  @default_category_uid 1
  @default_activity_id 1
  @default_type_uid 100_801
  @default_status_id 1

  @spec route_transition(map(), map(), keyword()) :: :ok | {:error, term()}
  def route_transition(previous_worker, updated_worker, opts \\ [])

  def route_transition(previous_worker, updated_worker, opts)
      when is_map(previous_worker) and is_map(updated_worker) do
    actor = Keyword.get(opts, :actor, SystemActor.system(:camera_analysis_worker_alert_router))
    record_event = Keyword.get(opts, :record_event, &record_event/2)
    broadcast_event = Keyword.get(opts, :broadcast_event, &EventsPubSub.broadcast_event/1)
    create_alert = Keyword.get(opts, :create_alert, &create_alert/2)
    list_active_alerts = Keyword.get(opts, :list_active_alerts, &list_active_alerts/2)
    resolve_alert = Keyword.get(opts, :resolve_alert, &resolve_alert/3)

    previous_alert_state = map_value(previous_worker, :alert_state)
    alert_state = map_value(updated_worker, :alert_state)

    if previous_alert_state == alert_state do
      :ok
    else
      transitions =
        previous_worker
        |> build_transition_steps(updated_worker, opts)
        |> Enum.reject(&is_nil/1)

      Enum.reduce_while(transitions, :ok, fn transition, :ok ->
        case route_step(
               transition,
               actor,
               record_event,
               broadcast_event,
               create_alert,
               list_active_alerts,
               resolve_alert
             ) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  def route_transition(_previous_worker, _updated_worker, _opts),
    do: {:error, :invalid_transition}

  @spec routed_alert_key(map() | String.t(), String.t() | nil) :: String.t() | nil
  def routed_alert_key(worker, alert_state \\ nil)

  def routed_alert_key(worker, alert_state) when is_map(worker) do
    routed_alert_key(
      map_value(worker, :worker_id),
      alert_state || map_value(worker, :alert_state)
    )
  end

  def routed_alert_key(worker_id, alert_state)
      when is_binary(worker_id) and is_binary(alert_state) do
    "camera_analysis_worker:#{worker_id}:#{alert_state}"
  end

  def routed_alert_key(_worker_id, _alert_state), do: nil

  @spec routed_alert_context(map()) :: map()
  def routed_alert_context(worker) when is_map(worker) do
    alert_state = map_value(worker, :alert_state)
    alert_key = routed_alert_key(worker, alert_state)

    %{
      routed_alert_active: map_value(worker, :alert_active, false) and is_binary(alert_key),
      routed_alert_key: alert_key,
      routed_alert_source_type: if(is_binary(alert_key), do: "event"),
      routed_alert_source_id: alert_key,
      routed_alert_title: if(is_binary(alert_key), do: default_alert_title(worker, alert_state))
    }
  end

  def routed_alert_context(_worker) do
    %{
      routed_alert_active: false,
      routed_alert_key: nil,
      routed_alert_source_type: nil,
      routed_alert_source_id: nil,
      routed_alert_title: nil
    }
  end

  defp route_step(
         %{kind: :activate} = transition,
         actor,
         record_event,
         broadcast_event,
         create_alert,
         _list_active_alerts,
         _resolve_alert
       ) do
    attrs = build_event_attrs(transition)

    with {:ok, event} <- record_event.(attrs, actor),
         :ok <- broadcast_event.(event),
         {:ok, _alert} <- create_alert.(build_alert_attrs(transition, event), actor) do
      :ok
    end
  end

  defp route_step(
         %{kind: :clear} = transition,
         actor,
         record_event,
         broadcast_event,
         _create_alert,
         list_active_alerts,
         resolve_alert
       ) do
    attrs = build_event_attrs(transition)

    with {:ok, event} <- record_event.(attrs, actor),
         :ok <- broadcast_event.(event),
         {:ok, alerts} <- list_active_alerts.(transition.routing_key, actor) do
      resolve_alerts(alerts, event, actor, resolve_alert, transition)
    end
  end

  defp build_transition_steps(previous_worker, updated_worker, opts) do
    previous_alert_state = map_value(previous_worker, :alert_state)
    alert_state = map_value(updated_worker, :alert_state)

    [
      clear_transition(previous_worker, updated_worker, previous_alert_state, opts),
      activate_transition(updated_worker, previous_alert_state, alert_state, opts)
    ]
  end

  defp clear_transition(previous_worker, updated_worker, previous_alert_state, opts)
       when is_binary(previous_alert_state) do
    %{
      kind: :clear,
      worker: build_worker_context(previous_worker, updated_worker),
      previous_alert_state: previous_alert_state,
      alert_state: nil,
      reason: map_value(updated_worker, :alert_reason),
      transition_source: Keyword.get(opts, :transition_source, "runtime"),
      relay_boundary: Keyword.get(opts, :relay_boundary, "core_elx"),
      relay_session_id: Keyword.get(opts, :relay_session_id),
      branch_id: Keyword.get(opts, :branch_id),
      routing_key: routed_alert_key(previous_worker, previous_alert_state)
    }
  end

  defp clear_transition(_previous_worker, _updated_worker, _previous_alert_state, _opts), do: nil

  defp activate_transition(updated_worker, previous_alert_state, alert_state, opts)
       when is_binary(alert_state) and previous_alert_state != alert_state do
    %{
      kind: :activate,
      worker: build_worker_context(updated_worker, updated_worker),
      previous_alert_state: previous_alert_state,
      alert_state: alert_state,
      reason: map_value(updated_worker, :alert_reason),
      transition_source: Keyword.get(opts, :transition_source, "runtime"),
      relay_boundary: Keyword.get(opts, :relay_boundary, "core_elx"),
      relay_session_id: Keyword.get(opts, :relay_session_id),
      branch_id: Keyword.get(opts, :branch_id),
      routing_key: routed_alert_key(updated_worker, alert_state)
    }
  end

  defp activate_transition(_updated_worker, _previous_alert_state, _alert_state, _opts), do: nil

  defp build_worker_context(source_worker, fallback_worker) do
    %{
      worker_id: map_value(source_worker, :worker_id) || map_value(fallback_worker, :worker_id),
      display_name:
        map_value(source_worker, :display_name) || map_value(fallback_worker, :display_name),
      adapter: map_value(source_worker, :adapter, map_value(fallback_worker, :adapter, "http")),
      capabilities:
        map_value(source_worker, :capabilities, map_value(fallback_worker, :capabilities, [])),
      health_status:
        map_value(source_worker, :health_status, map_value(fallback_worker, :health_status)),
      health_reason:
        map_value(source_worker, :health_reason, map_value(fallback_worker, :health_reason)),
      consecutive_failures:
        map_value(
          source_worker,
          :consecutive_failures,
          map_value(fallback_worker, :consecutive_failures, 0)
        ),
      flapping: map_value(source_worker, :flapping, map_value(fallback_worker, :flapping, false)),
      flapping_transition_count:
        map_value(
          source_worker,
          :flapping_transition_count,
          map_value(fallback_worker, :flapping_transition_count, 0)
        ),
      requested_capability:
        map_value(
          source_worker,
          :requested_capability,
          map_value(fallback_worker, :requested_capability)
        ),
      selection_mode:
        map_value(source_worker, :selection_mode, map_value(fallback_worker, :selection_mode)),
      endpoint_url:
        map_value(source_worker, :endpoint_url, map_value(fallback_worker, :endpoint_url))
    }
  end

  defp build_event_attrs(transition) do
    {severity_id, severity} = severity_for_transition(transition)
    worker_id = transition.worker.worker_id
    alert_state = transition.alert_state || transition.previous_alert_state

    %{
      id: Ash.UUID.generate(),
      time: DateTime.truncate(DateTime.utc_now(), :microsecond),
      class_uid: @default_class_uid,
      category_uid: @default_category_uid,
      type_uid: @default_type_uid,
      activity_id: @default_activity_id,
      activity_name: activity_name(transition.kind),
      severity_id: severity_id,
      severity: severity,
      message: event_message(transition),
      status_id: @default_status_id,
      status: status_name(transition.kind),
      status_code: status_code(transition.kind, alert_state),
      status_detail: transition.reason || alert_state,
      metadata: event_metadata(transition),
      observables: event_observables(transition),
      actor: %{
        "app_name" => "serviceradar.core",
        "process" => "camera_analysis_worker_alert_router",
        "worker_id" => worker_id
      },
      device: %{},
      src_endpoint: %{},
      dst_endpoint: %{},
      log_name: log_name(transition.kind),
      log_provider: @provider,
      log_level: log_level(severity_id),
      log_version: "camera_analysis_worker_alert.v1",
      unmapped: %{
        "worker" => %{
          "worker_id" => worker_id,
          "display_name" => transition.worker.display_name,
          "adapter" => transition.worker.adapter,
          "capabilities" => transition.worker.capabilities,
          "health_status" => transition.worker.health_status,
          "health_reason" => transition.worker.health_reason,
          "consecutive_failures" => transition.worker.consecutive_failures,
          "flapping" => transition.worker.flapping,
          "flapping_transition_count" => transition.worker.flapping_transition_count,
          "requested_capability" => transition.worker.requested_capability,
          "selection_mode" => transition.worker.selection_mode,
          "endpoint_url" => transition.worker.endpoint_url
        }
      },
      raw_data: Jason.encode!(event_metadata(transition))
    }
  end

  defp build_alert_attrs(transition, event) do
    %{
      title: default_alert_title(transition.worker, transition.alert_state),
      description: event.message,
      severity: alert_severity(transition.alert_state),
      source_type: :event,
      source_id: transition.routing_key,
      event_id: event.id,
      event_time: event.time,
      metadata:
        event.metadata
        |> Map.put("event_id", event.id)
        |> Map.put("log_name", event.log_name),
      tags: alert_tags(transition)
    }
  end

  defp event_message(%{kind: :activate, worker: worker, alert_state: alert_state}) do
    "Camera analysis worker #{worker.display_name || worker.worker_id} alert activated: #{alert_state}"
  end

  defp event_message(%{kind: :clear, worker: worker, previous_alert_state: previous_alert_state}) do
    "Camera analysis worker #{worker.display_name || worker.worker_id} alert cleared: #{previous_alert_state}"
  end

  defp event_metadata(transition) do
    %{
      "camera_analysis_worker_id" => transition.worker.worker_id,
      "camera_analysis_worker_display_name" => transition.worker.display_name,
      "camera_analysis_worker_adapter" => transition.worker.adapter,
      "camera_analysis_worker_capabilities" => transition.worker.capabilities,
      "camera_analysis_worker_health_status" => transition.worker.health_status,
      "camera_analysis_worker_health_reason" => transition.worker.health_reason,
      "camera_analysis_worker_consecutive_failures" => transition.worker.consecutive_failures,
      "camera_analysis_worker_flapping" => transition.worker.flapping,
      "camera_analysis_worker_flapping_transition_count" =>
        transition.worker.flapping_transition_count,
      "analysis_worker_requested_capability" => transition.worker.requested_capability,
      "analysis_worker_selection_mode" => transition.worker.selection_mode,
      "alert_transition" => Atom.to_string(transition.kind),
      "alert_state" => transition.alert_state,
      "previous_alert_state" => transition.previous_alert_state,
      "alert_reason" => transition.reason,
      "routed_alert_key" => transition.routing_key,
      "relay_boundary" => transition.relay_boundary,
      "relay_session_id" => transition.relay_session_id,
      "analysis_branch_id" => transition.branch_id,
      "transition_source" => transition.transition_source
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp event_observables(transition) do
    Enum.reject(
      [
        observable(transition.worker.worker_id, "Analysis Worker ID"),
        observable(transition.routing_key, "Routed Alert Key"),
        observable(transition.alert_state || transition.previous_alert_state, "Alert State"),
        observable(transition.worker.requested_capability, "Requested Capability")
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

  defp create_alert(attrs, actor) do
    Ash.create(Alert, attrs, action: :trigger, actor: actor, domain: ServiceRadar.Monitoring)
  end

  defp list_active_alerts(routing_key, actor) when is_binary(routing_key) do
    query =
      Alert
      |> Ash.Query.for_read(:active, %{}, actor: actor)
      |> Ash.Query.filter(source_type == :event and source_id == ^routing_key)

    Ash.read(query, actor: actor, domain: ServiceRadar.Monitoring)
  end

  defp list_active_alerts(_routing_key, _actor), do: {:ok, []}

  defp resolve_alerts(alerts, event, actor, resolve_alert, transition) do
    Enum.reduce_while(alerts, :ok, fn alert, :ok ->
      case resolve_alert.(
             alert,
             [
               actor: actor,
               resolved_by: "camera_analysis_worker_alert_router",
               resolution_note:
                 "Worker alert cleared via #{transition.routing_key || "unknown"} (event #{event.id})"
             ],
             event
           ) do
        {:ok, _resolved_alert} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp resolve_alert(alert, opts, _event) do
    actor = Keyword.fetch!(opts, :actor)

    args = %{
      resolved_by: Keyword.get(opts, :resolved_by),
      resolution_note: Keyword.get(opts, :resolution_note)
    }

    Ash.update(alert, args, action: :resolve, actor: actor, domain: ServiceRadar.Monitoring)
  end

  defp default_alert_title(worker, alert_state) do
    "Camera Analysis Worker Alert: #{worker.display_name || worker.worker_id} (#{alert_state})"
  end

  defp alert_tags(transition) do
    Enum.reject(["camera-analysis", "analysis-worker", transition.alert_state], &is_nil/1)
  end

  defp severity_for_transition(%{kind: :clear}), do: {1, "Informational"}
  defp severity_for_transition(%{alert_state: "failover_exhausted"}), do: {4, "High"}
  defp severity_for_transition(%{alert_state: "unhealthy"}), do: {3, "Medium"}
  defp severity_for_transition(%{alert_state: "flapping"}), do: {2, "Low"}
  defp severity_for_transition(_transition), do: {2, "Low"}

  defp alert_severity("failover_exhausted"), do: :critical
  defp alert_severity("unhealthy"), do: :warning
  defp alert_severity("flapping"), do: :warning
  defp alert_severity(_), do: :warning

  defp status_name(:activate), do: "Failure"
  defp status_name(:clear), do: "Success"

  defp status_code(:activate, alert_state), do: "analysis_worker_alert_activated:#{alert_state}"
  defp status_code(:clear, alert_state), do: "analysis_worker_alert_cleared:#{alert_state}"

  defp activity_name(:activate), do: "Activate"
  defp activity_name(:clear), do: "Clear"

  defp log_name(:activate), do: @activation_log_name
  defp log_name(:clear), do: @clear_log_name

  defp log_level(4), do: "error"
  defp log_level(3), do: "warning"
  defp log_level(2), do: "warning"
  defp log_level(_), do: "info"

  defp map_value(map, key, default \\ nil)

  defp map_value(map, key, default) when is_map(map) do
    Map.get(map, key, Map.get(map, to_string(key), default))
  end

  defp map_value(_map, _key, default), do: default
end
