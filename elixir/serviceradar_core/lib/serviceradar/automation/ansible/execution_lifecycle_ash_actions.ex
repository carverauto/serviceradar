defmodule ServiceRadar.Automation.Ansible.ExecutionLifecycleAshActions do
  @moduledoc false
  @behaviour ServiceRadar.Automation.Ansible.ExecutionLifecycleActions

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Automation.Ansible.AutomationExecution
  alias ServiceRadar.Automation.Ansible.AutomationExecutionTarget
  alias ServiceRadar.Automation.Ansible.AutomationTargetHold

  require Ash.Expr

  @actor SystemActor.system(:ansible_execution_lifecycle)

  @impl true
  def bind_accepted_job(execution, snapshot) do
    execution
    |> Ash.Changeset.for_update(
      :bind_job,
      %{
        awx_job_id: snapshot["awx_job_id"],
        accepted_job_snapshot: snapshot,
        started_at: DateTime.utc_now(),
        diagnostics: %{}
      },
      actor: @actor
    )
    |> Ash.Changeset.filter(Ash.Expr.expr(state == :dispatching and is_nil(awx_job_id)))
    |> Ash.update(actor: @actor)
  end

  @impl true
  def mark_scope_verified(execution, targets, evidence) do
    awx_job_id = value(execution, :awx_job_id)

    snapshot =
      execution
      |> value(:accepted_job_snapshot)
      |> ensure_map()
      |> Map.put("scope_verification", evidence)

    ServiceRadar.Repo.transaction(fn ->
      with {:ok, updated} <-
             execution
             |> Ash.Changeset.for_update(
               :record_scope_verified,
               %{accepted_job_snapshot: snapshot, diagnostics: %{}},
               actor: @actor
             )
             |> Ash.Changeset.filter(
               Ash.Expr.expr(state == :launching and awx_job_id == ^awx_job_id)
             )
             |> Ash.update(actor: @actor),
           :ok <- mark_targets_running(targets) do
        updated
      else
        {:error, reason} -> ServiceRadar.Repo.rollback(reason)
      end
    end)
  end

  @impl true
  def reject_scope(execution, targets, diagnostics) do
    diagnostics = stringify_keys(diagnostics)

    fn ->
      with {:ok, _updated} <-
             AutomationExecution.record_state(
               execution,
               %{state: :failed, ended_at: DateTime.utc_now(), diagnostics: diagnostics},
               actor: @actor
             ),
           :ok <- mark_targets_mismatched(targets, diagnostics),
           :ok <- maybe_hold_targets(execution, targets, diagnostics) do
        :ok
      else
        {:error, reason} -> ServiceRadar.Repo.rollback(reason)
      end
    end
    |> ServiceRadar.Repo.transaction()
    |> case do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp mark_targets_running(targets) do
    reduce_targets(targets, fn target ->
      AutomationExecutionTarget.record_status(
        target,
        %{status: :running, diagnostics: %{}},
        actor: @actor
      )
    end)
  end

  defp mark_targets_mismatched(targets, diagnostics) do
    reduce_targets(targets, fn target ->
      AutomationExecutionTarget.record_status(
        target,
        %{status: :scope_mismatch, diagnostics: diagnostics},
        actor: @actor
      )
    end)
  end

  defp reduce_targets(targets, callback) do
    Enum.reduce_while(targets, :ok, fn target, :ok ->
      case callback.(target) do
        {:ok, _updated} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp maybe_hold_targets(_execution, _targets, %{"mutating?" => false}), do: :ok

  defp maybe_hold_targets(execution, targets, diagnostics) do
    transaction_id = Ash.UUID.generate()

    reduce_targets(targets, fn target ->
      ensure_hold(execution, target, transaction_id, diagnostics)
    end)
  end

  defp ensure_hold(execution, target, transaction_id, diagnostics) do
    device_uid = value(target, :canonical_device_uid)

    attrs = %{
      canonical_device_uid: device_uid,
      trigger_membership_id: value(target, :membership_id),
      trigger_execution_target_id: value(target, :id) || value(target, :execution_target_id),
      transaction_id: transaction_id,
      generation: max(value(target, :membership_generation) || 1, 1),
      trigger_phase: :unknown,
      reason: to_string(diagnostics["reason"]),
      policy_digest: value(execution, :snapshot_digest),
      evidence_digest: diagnostics["source_digest"],
      held_at: DateTime.utc_now(),
      diagnostics: diagnostics
    }

    case AutomationTargetHold.place_hold(attrs, actor: @actor) do
      {:ok, hold} ->
        {:ok, hold}

      {:error, create_error} ->
        case AutomationTargetHold.get_active_for_device(device_uid, actor: @actor) do
          {:ok, hold} when not is_nil(hold) -> {:ok, hold}
          _ -> {:error, create_error}
        end
    end
  end

  defp stringify_keys(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp ensure_map(map) when is_map(map), do: map
  defp ensure_map(_), do: %{}

  defp value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp value(_map, _key), do: nil
end
