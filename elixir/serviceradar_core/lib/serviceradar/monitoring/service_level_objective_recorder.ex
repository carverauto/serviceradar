defmodule ServiceRadar.Monitoring.ServiceLevelObjectiveRecorder do
  @moduledoc """
  Persists SLO evaluations and emits normalized operational events.

  The evaluator remains side-effect free. This module is the runtime boundary
  that records the computed evaluation, refreshes the SLO summary fields, and
  writes an OCSF event that downstream event and alert pipelines can consume.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.EventWriter.OCSF
  alias ServiceRadar.Monitoring
  alias ServiceRadar.Monitoring.OcsfEvent
  alias ServiceRadar.Monitoring.ServiceLevelObjectiveEvaluation
  alias ServiceRadar.Monitoring.ServiceLevelObjectiveEvaluator

  @event_family "slo_evaluation"
  @log_name "monitoring.slo.evaluation"

  @doc """
  Evaluate observations for an SLO, persist the result, and optionally emit an event.

  Options:

  - `:actor` - Ash actor used for the writes. Defaults to a system SLO evaluator actor.
  - `:emit_event?` - when false, skip OCSF event creation. Defaults to true.
  """
  def evaluate_and_record(slo, observations, opts \\ []) do
    actor = Keyword.get(opts, :actor, SystemActor.system(:slo_evaluator))

    with {:ok, attrs} <- ServiceLevelObjectiveEvaluator.evaluate(slo, observations),
         {:ok, evaluation} <-
           ServiceLevelObjectiveEvaluation.record_evaluation(attrs, actor: actor),
         {:ok, _updated_slo} <- record_summary(slo, evaluation, actor) do
      maybe_emit_event(slo, evaluation, actor, opts)
    end
  end

  defp record_summary(slo, evaluation, actor) do
    slo
    |> Ash.Changeset.for_update(
      :record_evaluation_summary,
      %{
        last_evaluated_at: evaluation.evaluated_at,
        last_compliance_state: evaluation.compliance_state,
        last_budget_remaining_basis_points: evaluation.budget_remaining_basis_points,
        last_burn_rate: evaluation.burn_rate_short || evaluation.burn_rate_long
      },
      actor: actor
    )
    |> Ash.update(actor: actor)
  end

  defp maybe_emit_event(slo, evaluation, actor, opts) do
    if Keyword.get(opts, :emit_event?, true) do
      with {:ok, event} <-
             Ash.create(OcsfEvent, event_attrs(slo, evaluation, actor),
               action: :record,
               actor: actor,
               domain: Monitoring
             ) do
        attach_event(evaluation, event, actor)
      end
    else
      {:ok, evaluation}
    end
  end

  defp attach_event(evaluation, event, actor) do
    evaluation
    |> Ash.Changeset.for_update(:update_budget_state, %{event_id: event.id}, actor: actor)
    |> Ash.update(actor: actor)
  end

  defp event_attrs(slo, evaluation, actor) do
    activity_id = OCSF.activity_log_update()
    severity_id = severity_id(evaluation.severity)
    status_id = status_id(evaluation.compliance_state)
    metadata = event_metadata(slo, evaluation)

    %{
      time: DateTime.utc_now(),
      class_uid: OCSF.class_event_log_activity(),
      category_uid: OCSF.category_system_activity(),
      type_uid: OCSF.type_uid(OCSF.class_event_log_activity(), activity_id),
      activity_id: activity_id,
      activity_name: OCSF.log_activity_name(activity_id),
      severity_id: severity_id,
      severity: OCSF.severity_name(severity_id),
      message: event_message(slo, evaluation),
      status_id: status_id,
      status: OCSF.status_name(status_id),
      metadata:
        OCSF.build_metadata(
          version: "1.7.0",
          product_name: "ServiceRadar Core",
          correlation_uid: "service_level_objective:#{evaluation.slo_id}"
        ),
      observables:
        observables([
          observable(evaluation.slo_id, "Service Level Objective ID"),
          observable(value(slo, :slo_key), "Service Level Objective Key"),
          observable(evaluation.id, "Service Level Objective Evaluation ID"),
          observable(evaluation.compliance_state, "SLO Compliance State")
        ]),
      actor: actor_object(actor),
      log_name: @log_name,
      log_provider: "serviceradar.core",
      log_level: log_level(severity_id),
      unmapped: metadata,
      raw_data: Jason.encode!(metadata)
    }
  end

  defp event_metadata(slo, evaluation) do
    %{
      "event_family" => @event_family,
      "service_level_objective_id" => stringify(evaluation.slo_id),
      "service_level_objective_key" => value(slo, :slo_key),
      "service_level_objective_name" => value(slo, :name),
      "service_group_id" => stringify(value(slo, :service_group_id)),
      "owner" => value(slo, :owner),
      "evaluation_id" => stringify(evaluation.id),
      "evaluation_key" => evaluation.evaluation_key,
      "compliance_state" => stringify(evaluation.compliance_state),
      "severity" => stringify(evaluation.severity),
      "goal_basis_points" => evaluation.goal_basis_points,
      "compliance_basis_points" => evaluation.compliance_basis_points,
      "eligible_events" => evaluation.eligible_events,
      "good_events" => evaluation.good_events,
      "bad_events" => evaluation.bad_events,
      "total_windows" => evaluation.total_windows,
      "good_windows" => evaluation.good_windows,
      "bad_windows" => evaluation.bad_windows,
      "error_budget_total" => evaluation.error_budget_total,
      "error_budget_consumed" => evaluation.error_budget_consumed,
      "error_budget_remaining" => evaluation.error_budget_remaining,
      "budget_remaining_basis_points" => evaluation.budget_remaining_basis_points,
      "burn_rate_short" => stringify(evaluation.burn_rate_short),
      "burn_rate_long" => stringify(evaluation.burn_rate_long),
      "period_started_at" => iso8601(evaluation.period_started_at),
      "period_ended_at" => iso8601(evaluation.period_ended_at),
      "evaluated_at" => iso8601(evaluation.evaluated_at)
    }
  end

  defp event_message(slo, evaluation) do
    name = value(slo, :name) || value(slo, :slo_key) || evaluation.slo_id
    "SLO #{name} evaluated as #{evaluation.compliance_state}"
  end

  defp severity_id(:critical), do: OCSF.severity_critical()
  defp severity_id("critical"), do: OCSF.severity_critical()
  defp severity_id(:warning), do: OCSF.severity_medium()
  defp severity_id("warning"), do: OCSF.severity_medium()
  defp severity_id(_severity), do: OCSF.severity_informational()

  defp status_id(:compliant), do: OCSF.status_success()
  defp status_id("compliant"), do: OCSF.status_success()
  defp status_id(:noncompliant), do: OCSF.status_failure()
  defp status_id("noncompliant"), do: OCSF.status_failure()
  defp status_id(_state), do: OCSF.status_other()

  defp log_level(severity_id) do
    cond do
      severity_id >= OCSF.severity_critical() -> "critical"
      severity_id >= OCSF.severity_high() -> "error"
      severity_id >= OCSF.severity_medium() -> "warning"
      true -> "info"
    end
  end

  defp actor_object(nil), do: %{user: %{uid: "system", name: "ServiceRadar SLO Evaluator"}}

  defp actor_object(actor) when is_map(actor) do
    %{
      user: %{
        uid: stringify(value(actor, :id) || "system"),
        name: stringify(value(actor, :email) || value(actor, :id) || "ServiceRadar SLO Evaluator")
      }
    }
  end

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

  defp iso8601(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp iso8601(_value), do: nil

  defp value(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp value(struct, key), do: Map.get(struct, key)

  defp stringify(nil), do: nil
  defp stringify(value) when is_binary(value), do: value
  defp stringify(value), do: to_string(value)
end
