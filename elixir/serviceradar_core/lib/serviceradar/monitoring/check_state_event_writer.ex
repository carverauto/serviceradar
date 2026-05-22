defmodule ServiceRadar.Monitoring.CheckStateEventWriter do
  @moduledoc """
  Emits OCSF events for materialized check-state observations.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.EventWriter.OCSF
  alias ServiceRadar.Monitoring
  alias ServiceRadar.Monitoring.CheckInstance
  alias ServiceRadar.Monitoring.LatestCheckState
  alias ServiceRadar.Monitoring.OcsfEvent

  require Logger

  @event_family "check_state_transition"
  @log_name "monitoring.check_state"

  @doc """
  Emit a check-state event when the check instance event policy requests it.

  Empty event policies default to status-change events. Explicit policies may
  set `"emit_on"`/`:emit_on` to `status_change`, `failure`, `recovery`,
  `every_result`, or `all`.
  """
  def maybe_write(check_instance, previous_state, state, opts \\ [])

  def maybe_write(
        %CheckInstance{} = check_instance,
        previous_state,
        %LatestCheckState{} = state,
        opts
      ) do
    actor = Keyword.get(opts, :actor, SystemActor.system(:check_state_event_writer))
    transition = transition(previous_state, state)

    if emit?(check_instance.event_policy_snapshot, transition, state) do
      write_event(check_instance, previous_state, state, transition, actor)
    else
      :ok
    end
  rescue
    exception ->
      Logger.warning("Failed to write check-state OCSF event",
        check_instance_id: Map.get(check_instance || %{}, :id),
        reason: Exception.message(exception)
      )

      :ok
  end

  def maybe_write(_check_instance, _previous_state, _state, _opts), do: :ok

  defp write_event(check_instance, previous_state, state, transition, actor) do
    case Ash.create(
           OcsfEvent,
           event_attrs(check_instance, previous_state, state, transition, actor),
           action: :record,
           actor: actor,
           domain: Monitoring
         ) do
      {:ok, _event} ->
        mark_event_emitted(state, actor)
        :ok

      {:error, reason} ->
        Logger.warning("Failed to create check-state OCSF event",
          check_instance_id: check_instance.id,
          reason: inspect(reason)
        )

        :ok
    end
  end

  defp mark_event_emitted(state, actor) do
    state
    |> Ash.Changeset.for_update(:mark_event_emitted, %{event_emitted_at: DateTime.utc_now()},
      actor: actor
    )
    |> Ash.update(actor: actor)
  end

  defp event_attrs(check_instance, previous_state, state, transition, actor) do
    activity_id = OCSF.activity_log_update()
    severity_id = severity_id(state.status)
    status_id = status_id(state.status)
    metadata = event_metadata(check_instance, previous_state, state, transition)

    %{
      time: state.last_observed_at || DateTime.utc_now(),
      class_uid: OCSF.class_event_log_activity(),
      category_uid: OCSF.category_system_activity(),
      type_uid: OCSF.type_uid(OCSF.class_event_log_activity(), activity_id),
      activity_id: activity_id,
      activity_name: OCSF.log_activity_name(activity_id),
      severity_id: severity_id,
      severity: OCSF.severity_name(severity_id),
      message: event_message(check_instance, state, transition),
      status_id: status_id,
      status: OCSF.status_name(status_id),
      metadata:
        OCSF.build_metadata(
          version: "1.7.0",
          product_name: "ServiceRadar Core",
          correlation_uid: "check_instance:#{check_instance.id}"
        ),
      observables:
        observables([
          observable(check_instance.id, "Check Instance ID"),
          observable(check_instance.descriptor_id, "Check Descriptor ID"),
          observable(check_instance.monitored_service_id, "Monitored Service ID"),
          observable(check_instance.device_uid, "Device UID"),
          observable(state.status, "Check Status")
        ]),
      actor: actor_object(actor),
      device: device_object(check_instance),
      dst_endpoint: endpoint_object(check_instance.target_snapshot),
      log_name: @log_name,
      log_provider: "serviceradar.core",
      log_level: log_level(severity_id),
      unmapped: metadata,
      raw_data: Jason.encode!(metadata)
    }
  end

  defp event_metadata(check_instance, previous_state, state, transition) do
    %{
      "event_family" => @event_family,
      "transition" => stringify(transition),
      "check_instance_id" => stringify(check_instance.id),
      "check_key" => check_instance.check_key,
      "monitoring_binding_id" => stringify(check_instance.monitoring_binding_id),
      "monitored_service_id" => stringify(check_instance.monitored_service_id),
      "device_uid" => check_instance.device_uid,
      "descriptor_id" => check_instance.descriptor_id,
      "descriptor_version" => check_instance.descriptor_version,
      "capability_kind" => stringify(check_instance.capability_kind),
      "status" => stringify(state.status),
      "previous_status" => stringify(previous_status(previous_state)),
      "status_changed_at" => iso8601(state.status_changed_at),
      "last_observed_at" => iso8601(state.last_observed_at),
      "response_time_ms" => state.response_time_ms,
      "consecutive_failures" => state.consecutive_failures,
      "summary" => state.summary,
      "vantage_kind" => stringify(state.vantage_kind),
      "vantage_id" => state.vantage_id,
      "agent_id" => state.agent_id
    }
  end

  defp event_message(check_instance, state, transition) do
    target =
      check_instance.target_snapshot
      |> endpoint_label()
      |> Kernel.||(check_instance.check_key)

    "Check #{check_instance.descriptor_id} for #{target} #{transition} to #{state.status}"
  end

  defp transition(nil, _state), do: :initial

  defp transition(%LatestCheckState{} = previous_state, %LatestCheckState{} = state) do
    cond do
      previous_state.status == state.status -> :observed
      ok?(previous_state.status) and not ok?(state.status) -> :failure
      not ok?(previous_state.status) and ok?(state.status) -> :recovery
      true -> :status_change
    end
  end

  defp emit?(policy, transition, state) do
    emit_on = emit_on(policy)

    "all" in emit_on or
      "every_result" in emit_on or
      ("status_change" in emit_on and transition != :observed) or
      ("failure" in emit_on and not ok?(state.status)) or
      ("recovery" in emit_on and transition == :recovery)
  end

  defp emit_on(policy) when policy in [nil, %{}], do: ["status_change"]

  defp emit_on(policy) when is_map(policy) do
    policy
    |> value(:emit_on)
    |> List.wrap()
    |> Enum.map(&stringify/1)
    |> Enum.map(&String.trim/1)
    |> Enum.map(&String.downcase/1)
    |> Enum.reject(&(&1 == ""))
    |> case do
      [] -> ["status_change"]
      values -> values
    end
  end

  defp emit_on(_policy), do: ["status_change"]

  defp ok?(:ok), do: true
  defp ok?("ok"), do: true
  defp ok?(_status), do: false

  defp severity_id(:critical), do: OCSF.severity_critical()
  defp severity_id("critical"), do: OCSF.severity_critical()
  defp severity_id(:warning), do: OCSF.severity_medium()
  defp severity_id("warning"), do: OCSF.severity_medium()
  defp severity_id(_status), do: OCSF.severity_informational()

  defp status_id(:ok), do: OCSF.status_success()
  defp status_id("ok"), do: OCSF.status_success()
  defp status_id(:warning), do: OCSF.status_other()
  defp status_id("warning"), do: OCSF.status_other()
  defp status_id(_status), do: OCSF.status_failure()

  defp log_level(severity_id) do
    cond do
      severity_id >= OCSF.severity_critical() -> "critical"
      severity_id >= OCSF.severity_high() -> "error"
      severity_id >= OCSF.severity_medium() -> "warning"
      true -> "info"
    end
  end

  defp actor_object(actor) when is_map(actor) do
    %{
      user: %{
        uid: stringify(value(actor, :id) || "system"),
        name:
          stringify(
            value(actor, :email) || value(actor, :id) || "ServiceRadar Check State Writer"
          )
      }
    }
  end

  defp actor_object(_actor),
    do: %{user: %{uid: "system", name: "ServiceRadar Check State Writer"}}

  defp device_object(%CheckInstance{device_uid: nil}), do: %{}
  defp device_object(%CheckInstance{device_uid: device_uid}), do: %{uid: device_uid}

  defp endpoint_object(target_snapshot) when is_map(target_snapshot) do
    url = value(target_snapshot, :endpoint_url) || value(target_snapshot, :url)

    case url && URI.parse(url) do
      %URI{} = uri when is_binary(uri.host) ->
        OCSF.build_endpoint(
          hostname: uri.host,
          port: uri.port,
          name: url
        )

      _ ->
        OCSF.build_endpoint(
          hostname: value(target_snapshot, :host),
          ip: value(target_snapshot, :ip),
          port: value(target_snapshot, :port),
          name: endpoint_label(target_snapshot)
        )
    end
  end

  defp endpoint_object(_target_snapshot), do: %{}

  defp endpoint_label(target_snapshot) when is_map(target_snapshot) do
    value(target_snapshot, :endpoint_url) ||
      value(target_snapshot, :url) ||
      value(target_snapshot, :host) ||
      value(target_snapshot, :ip) ||
      value(target_snapshot, :service_name)
  end

  defp endpoint_label(_target_snapshot), do: nil

  defp observables(items), do: Enum.reject(items, &is_nil/1)

  defp observable(nil, _name), do: nil
  defp observable("", _name), do: nil

  defp observable(value, name),
    do: %{
      "name" => stringify(value),
      "type" => "string",
      "value" => stringify(value),
      "caption" => name
    }

  defp previous_status(nil), do: nil
  defp previous_status(%LatestCheckState{} = state), do: state.status

  defp iso8601(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp iso8601(_value), do: nil

  defp value(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))

  defp stringify(nil), do: nil
  defp stringify(value) when is_binary(value), do: value
  defp stringify(value), do: to_string(value)
end
