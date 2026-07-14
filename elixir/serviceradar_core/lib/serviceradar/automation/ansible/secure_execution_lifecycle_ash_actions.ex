defmodule ServiceRadar.Automation.Ansible.SecureExecutionLifecycleAshActions do
  @moduledoc false
  @behaviour ServiceRadar.Automation.Ansible.SecureExecutionLifecycleActions

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Automation.Ansible.AutomationExecution
  alias ServiceRadar.Automation.Ansible.AutomationExecutionTarget
  alias ServiceRadar.Automation.Ansible.AutomationOperation
  alias ServiceRadar.Automation.Ansible.AutomationTargetHold
  alias ServiceRadar.Automation.CallbackGrants.CanonicalJSON

  require Ash.Expr

  @actor SystemActor.system(:secure_execution_lifecycle)

  @impl true
  def mark_running(operation, execution) do
    ServiceRadar.Repo.transaction(fn ->
      with {:ok, updated_execution} <- update_execution_running(execution),
           {:ok, updated_operation} <- update_operation_running(operation) do
        %{operation: updated_operation, execution: updated_execution}
      else
        {:error, reason} -> ServiceRadar.Repo.rollback(reason)
      end
    end)
  end

  @impl true
  def complete_terminal(operation, execution, target_outcomes, terminal_state, evidence) do
    now = DateTime.utc_now()

    ServiceRadar.Repo.transaction(fn ->
      with {:ok, updated_execution} <-
             execution
             |> Ash.Changeset.for_update(
               :record_state,
               %{state: terminal_state, ended_at: now, diagnostics: evidence},
               actor: @actor
             )
             |> Ash.Changeset.filter(
               Ash.Expr.expr(state == :running and awx_job_id == ^execution.awx_job_id)
             )
             |> Ash.update(actor: @actor),
           {:ok, updated_operation} <-
             operation
             |> Ash.Changeset.for_update(
               :record_state,
               %{state: terminal_state, ended_at: now, diagnostics: evidence},
               actor: @actor
             )
             |> Ash.Changeset.filter(Ash.Expr.expr(state == :running))
             |> Ash.update(actor: @actor),
           :ok <- update_target_outcomes(target_outcomes) do
        %{
          operation: updated_operation,
          execution: updated_execution,
          target_outcomes: target_outcomes
        }
      else
        {:error, reason} -> ServiceRadar.Repo.rollback(reason)
      end
    end)
  end

  @impl true
  def fail_closed(operation, execution, targets, state, diagnostics) do
    now = DateTime.utc_now()

    ServiceRadar.Repo.transaction(fn ->
      with {:ok, updated_execution} <-
             AutomationExecution.record_state(
               execution,
               %{state: state, ended_at: now, diagnostics: diagnostics},
               actor: @actor
             ),
           {:ok, updated_operation} <-
             AutomationOperation.record_state(
               operation,
               %{state: state, ended_at: now, diagnostics: diagnostics},
               actor: @actor
             ),
           :ok <- mark_failed_targets(targets, state, diagnostics),
           :ok <- maybe_hold_targets(operation, execution, targets, diagnostics) do
        %{
          operation: updated_operation,
          execution: updated_execution,
          targets: targets
        }
      else
        {:error, reason} -> ServiceRadar.Repo.rollback(reason)
      end
    end)
  end

  defp update_execution_running(execution) do
    execution
    |> Ash.Changeset.for_update(
      :record_state,
      %{state: :running, diagnostics: %{}},
      actor: @actor
    )
    |> Ash.Changeset.filter(
      Ash.Expr.expr(state == :scope_verified and awx_job_id == ^execution.awx_job_id)
    )
    |> Ash.update(actor: @actor)
  end

  defp update_operation_running(operation) do
    operation
    |> Ash.Changeset.for_update(
      :record_state,
      %{state: :running, diagnostics: %{}},
      actor: @actor
    )
    |> Ash.Changeset.filter(Ash.Expr.expr(state == :dispatching))
    |> Ash.update(actor: @actor)
  end

  defp update_target_outcomes(outcomes) do
    Enum.reduce_while(outcomes, :ok, fn {target, status, diagnostics}, :ok ->
      case AutomationExecutionTarget.record_status(
             target,
             %{status: status, diagnostics: diagnostics},
             actor: @actor
           ) do
        {:ok, _updated} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp mark_failed_targets(targets, state, diagnostics) do
    status = if state == :dispatch_ambiguous, do: :scope_mismatch, else: :failed

    Enum.reduce_while(targets, :ok, fn target, :ok ->
      case AutomationExecutionTarget.record_status(
             target,
             %{status: status, diagnostics: diagnostics},
             actor: @actor
           ) do
        {:ok, _updated} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp maybe_hold_targets(%{mutating: false}, _execution, _targets, _diagnostics), do: :ok

  defp maybe_hold_targets(_operation, execution, targets, diagnostics) do
    transaction_id = Ash.UUID.generate()

    with {:ok, evidence_digest} <- CanonicalJSON.digest(diagnostics) do
      Enum.reduce_while(targets, :ok, fn target, :ok ->
        case ensure_hold(execution, target, transaction_id, evidence_digest, diagnostics) do
          {:ok, _hold} -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  defp ensure_hold(execution, target, transaction_id, evidence_digest, diagnostics) do
    device_uid = target.canonical_device_uid

    attrs = %{
      canonical_device_uid: device_uid,
      trigger_membership_id: target.membership_id,
      trigger_execution_target_id: target.id,
      transaction_id: transaction_id,
      generation: max(target.membership_generation || 1, 1),
      trigger_phase: :unknown,
      reason: diagnostics["reason"],
      policy_digest: execution.snapshot_digest,
      evidence_digest: evidence_digest,
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
end
