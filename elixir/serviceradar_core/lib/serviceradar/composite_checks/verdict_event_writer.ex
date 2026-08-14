defmodule ServiceRadar.CompositeChecks.VerdictEventWriter do
  @moduledoc """
  Records an OCSF event when a device's composite check verdict changes.

  Verdicts are derived state, not metrics, so they follow the core-originated
  OCSF event path — a system-actor `Ash.create/3` into `ocsf_events` — rather
  than JetStream. The JetStream-first rule in AGENTS.md governs metric
  ingestion; see `ServiceRadar.Credentials.CredentialEventWriter` for the same
  pattern on control-plane lifecycle events.

  Event write failures are logged and swallowed. The verdict has already been
  persisted by the time this runs, and failing the pass over a missing audit row
  would discard correct results.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.EventWriter.OCSF
  alias ServiceRadar.Monitoring.OcsfEvent

  require Logger

  @log_name "composite_check.verdict.changed"

  @spec write_transitions(map(), [map()]) :: :ok
  def write_transitions(_check, []), do: :ok

  def write_transitions(check, transitions) when is_list(transitions) do
    Enum.each(transitions, &write_transition(check, &1))
    :ok
  end

  defp write_transition(check, transition) do
    attrs = event_attrs(check, transition)

    case Ash.create(OcsfEvent, attrs,
           action: :record,
           actor: SystemActor.system(:composite_check_verdict_writer),
           domain: ServiceRadar.Monitoring
         ) do
      {:ok, _event} ->
        :ok

      {:error, error} ->
        log_failure(check, transition, inspect(error))
    end
  rescue
    exception -> log_failure(check, transition, Exception.message(exception))
  end

  defp log_failure(check, transition, reason) do
    Logger.warning("Failed to write composite check verdict event",
      check_id: Map.get(check, :id),
      device_uid: Map.get(transition, :device_uid),
      reason: reason
    )

    :ok
  end

  defp event_attrs(check, transition) do
    activity_id = OCSF.activity_log_update()
    severity_id = severity_for(transition.to_status)
    status_id = OCSF.status_success()
    unmapped = unmapped(check, transition)

    %{
      time: DateTime.utc_now(),
      class_uid: OCSF.class_event_log_activity(),
      category_uid: OCSF.category_system_activity(),
      type_uid: OCSF.type_uid(OCSF.class_event_log_activity(), activity_id),
      activity_id: activity_id,
      activity_name: OCSF.log_activity_name(activity_id),
      severity_id: severity_id,
      severity: OCSF.severity_name(severity_id),
      message: message(check, transition),
      status_id: status_id,
      status: OCSF.status_name(status_id),
      metadata:
        OCSF.build_metadata(
          product_name: "ServiceRadar Core",
          correlation_uid: "composite_check:#{Map.get(check, :id)}:#{transition.device_uid}"
        ),
      observables: [],
      actor: %{user: %{uid: "system", name: "ServiceRadar Composite Checks"}},
      log_name: @log_name,
      log_provider: "serviceradar.core",
      unmapped: unmapped,
      raw_data: Jason.encode!(unmapped)
    }
  end

  defp message(check, transition) do
    "Composite check #{Map.get(check, :name)} verdict for #{transition.device_uid} " <>
      "changed from #{transition.from_verdict || "none"} to #{transition.to_verdict}"
  end

  defp unmapped(check, transition) do
    %{
      "event_family" => "composite_check_verdict",
      "check_id" => to_string(Map.get(check, :id)),
      "check_slug" => Map.get(check, :slug),
      "check_name" => Map.get(check, :name),
      "device_uid" => transition.device_uid,
      "from_verdict" => transition.from_verdict,
      "to_verdict" => transition.to_verdict,
      "from_status" => transition.from_status && to_string(transition.from_status),
      "to_status" => to_string(transition.to_status),
      "inputs" => transition.inputs
    }
  end

  # A device that should be isolated but is not is a security finding, so it
  # gets a severity an operator will actually see. Recovering to healthy is
  # informational.
  defp severity_for(:down), do: OCSF.severity_high()
  defp severity_for(:degraded), do: OCSF.severity_medium()
  defp severity_for(_status), do: OCSF.severity_informational()

  @doc false
  def log_name, do: @log_name
end
