defmodule ServiceRadar.Automation.Ansible.MutationLifecycleAshActions do
  @moduledoc false
  @behaviour ServiceRadar.Automation.Ansible.MutationLifecycleActions

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Automation.Ansible.AutomationMutationPhase
  alias ServiceRadar.Automation.Ansible.AutomationTargetHold
  alias ServiceRadar.Automation.Ansible.SafeFailureEvidence

  @actor SystemActor.system(:ansible_mutation_lifecycle)
  @phase_attributes [
    :execution_target_id,
    :transaction_id,
    :generation,
    :idempotency_key,
    :previous_phase,
    :phase,
    :action,
    :template_id,
    :scm_revision,
    :policy_digest,
    :outcome_digest,
    :evidence_digest,
    :authenticated_source,
    :deadline_at,
    :occurred_at,
    :metadata
  ]

  @impl true
  def get_by_idempotency_key(target_id, idempotency_key) do
    AutomationMutationPhase.get_by_idempotency_key(target_id, idempotency_key, actor: @actor)
  end

  @impl true
  def list_for_target(target_id) do
    AutomationMutationPhase.list_for_target(target_id, actor: @actor)
  end

  @impl true
  def record_phase(attrs) do
    attrs
    |> Map.take(@phase_attributes)
    |> AutomationMutationPhase.record_authenticated(actor: @actor)
  end

  @impl true
  def record_phase_and_hold(context, attrs, reason) do
    record_with_hold(context, attrs, reason)
  end

  @impl true
  def record_unknown_and_hold(context, attrs, reason) do
    record_with_hold(context, attrs, reason)
  end

  defp record_with_hold(context, attrs, reason) do
    ServiceRadar.Repo.transaction(fn ->
      with {:ok, phase} <- record_phase(attrs),
           {:ok, hold} <- ensure_hold(context, attrs, reason) do
        %{phase: phase, hold: hold}
      else
        {:error, error} -> ServiceRadar.Repo.rollback(error)
      end
    end)
  end

  defp ensure_hold(context, attrs, reason) do
    target = value(context, :target)
    device_uid = value(target, :canonical_device_uid)
    failure_code = SafeFailureEvidence.code(reason)

    hold_attrs = %{
      canonical_device_uid: device_uid,
      trigger_membership_id: value(target, :membership_id),
      trigger_execution_target_id: value(target, :id),
      transaction_id: attrs.transaction_id,
      generation: attrs.generation,
      trigger_phase: attrs.phase,
      reason: failure_code,
      policy_digest: attrs.policy_digest,
      evidence_digest: attrs.evidence_digest,
      held_at: DateTime.utc_now(),
      diagnostics: %{
        "failure_reason" => failure_code,
        "fail_closed" => true
      },
      metadata: %{"source" => "automation.mutation_phase.v1"}
    }

    case AutomationTargetHold.place_hold(hold_attrs, actor: @actor) do
      {:ok, hold} ->
        {:ok, hold}

      {:error, create_error} ->
        case AutomationTargetHold.get_active_for_device(device_uid, actor: @actor) do
          {:ok, hold} when not is_nil(hold) -> {:ok, hold}
          _ -> {:error, create_error}
        end
    end
  end

  defp value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp value(_map, _key), do: nil
end
