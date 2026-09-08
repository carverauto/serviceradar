defmodule ServiceRadar.Automation.Ansible.SecureExecutionAuthorityContraction do
  @moduledoc """
  Durably terminalizes an unauthorized non-callback continuation.

  A launch denial has no remote child and therefore fails locally without a
  target hold. Once a controller-local AWX job ID is known, contraction marks
  the execution failed-closed, places holds for mutating targets, and commits a
  cancellation attempt in the same database transaction. Dispatch after that
  commit is only an optimization; recovery owns the durable retry.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Automation.Ansible.AutomationExecution
  alias ServiceRadar.Automation.Ansible.AutomationExecutionTarget
  alias ServiceRadar.Automation.Ansible.AutomationOperation

  alias ServiceRadar.Automation.Ansible.AutomationSecureExecutionCommandAttempt,
    as: Attempt

  alias ServiceRadar.Automation.Ansible.SafeFailureEvidence
  alias ServiceRadar.Automation.Ansible.SecureExecutionCommandContract, as: Contract
  alias ServiceRadar.Automation.Ansible.SecureExecutionCommandDispatcher
  alias ServiceRadar.Automation.Ansible.SecureExecutionLifecycle
  alias ServiceRadar.Repo

  require Logger

  @actor SystemActor.system(:secure_execution_authority_contraction)
  @cancel_deadline_seconds 60

  @spec deny(Attempt.t(), map(), term(), DateTime.t(), keyword()) ::
          {:ok, atom()} | {:error, term()}
  def deny(attempt, resources, reason, now, opts \\ [])

  def deny(%Attempt{stage: :launch_job} = attempt, resources, reason, %DateTime{} = now, opts)
      when is_map(resources) and is_list(opts) do
    with {:ok, _result} <-
           transaction(opts, fn -> deny_prelaunch(attempt, resources, reason, now, opts) end) do
      {:ok, :launch_denied}
    end
  rescue
    _ -> {:error, :secure_execution_authority_contraction_unavailable}
  catch
    _, _ -> {:error, :secure_execution_authority_contraction_unavailable}
  end

  def deny(
        %Attempt{expected_job_id: job_id} = attempt,
        resources,
        reason,
        %DateTime{} = now,
        opts
      )
      when is_integer(job_id) and job_id > 0 and is_map(resources) and is_list(opts) do
    with {:ok, request} <- Contract.cancel_job_request(job_id),
         {:ok, cancel_attrs} <- cancel_attempt_attrs(attempt, resources.execution, request, now),
         {:ok, next} <-
           transaction(opts, fn ->
             deny_known_child(attempt, resources, reason, now, cancel_attrs, opts)
           end) do
      dispatch_after_commit(next, opts)
      {:ok, :cancellation_planned}
    end
  rescue
    _ -> {:error, :secure_execution_authority_contraction_unavailable}
  catch
    _, _ -> {:error, :secure_execution_authority_contraction_unavailable}
  end

  def deny(_attempt, _resources, _reason, _now, _opts),
    do: {:error, :secure_execution_authority_contraction_job_unknown}

  defp deny_prelaunch(attempt, resources, reason, now, opts) do
    diagnostics = diagnostics(resources, reason, false)

    with {:ok, denied_attempt} <- deny_attempt(attempt, reason, now, opts),
         {:ok, execution} <-
           AutomationExecution.record_state(
             resources.execution,
             %{state: :failed, ended_at: now, diagnostics: diagnostics},
             actor: @actor
           ),
         {:ok, operation} <-
           AutomationOperation.record_state(
             resources.operation,
             %{state: :failed, ended_at: now, diagnostics: diagnostics},
             actor: @actor
           ),
         :ok <- mark_targets_failed(resources.targets, diagnostics) do
      %{attempt: denied_attempt, execution: execution, operation: operation}
    else
      {:error, denial_reason} -> rollback(opts, denial_reason)
    end
  end

  defp deny_known_child(attempt, resources, reason, now, cancel_attrs, opts) do
    with {:ok, denied_attempt} <- deny_attempt(attempt, reason, now, opts),
         {:ok, lifecycle} <-
           SecureExecutionLifecycle.fail_closed(
             resources.operation,
             resources.execution,
             resources.targets,
             :failed,
             reason,
             lifecycle_opts(opts, cancel_required: true)
           ),
         {:ok, cancel_attempt} <-
           attempt_store(opts).create_planned(cancel_attrs, actor: @actor) do
      _ = denied_attempt
      _ = lifecycle
      cancel_attempt
    else
      {:error, denial_reason} -> rollback(opts, denial_reason)
    end
  end

  defp deny_attempt(attempt, reason, now, opts) do
    attempt_store(opts).deny_incomplete(
      attempt,
      %{
        processed_at: now,
        outcome_code: "current_authority_denied",
        last_error_code: SafeFailureEvidence.code(reason)
      },
      actor: @actor
    )
  end

  defp cancel_attempt_attrs(attempt, execution, request, now) do
    Contract.build_attempt(
      %{
        operation_id: attempt.operation_id,
        execution_id: attempt.execution_id,
        controller_id: attempt.controller_id,
        dispatch_agent_id: attempt.dispatch_agent_id,
        dispatch_partition_id: attempt.dispatch_partition_id
      },
      execution,
      request,
      stage: :cancel_job,
      purpose: :terminal_cleanup,
      command_type: "awx.cancel_job",
      attempt: min((attempt.attempt || 0) + 1, 1_000),
      expected_job_id: attempt.expected_job_id,
      candidate_job_ids: [],
      deadline_at: DateTime.add(now, @cancel_deadline_seconds, :second)
    )
  end

  defp mark_targets_failed(targets, diagnostics) when is_list(targets) do
    Enum.reduce_while(targets, :ok, fn target, :ok ->
      case AutomationExecutionTarget.record_status(
             target,
             %{status: :failed, diagnostics: diagnostics},
             actor: @actor
           ) do
        {:ok, _updated} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp mark_targets_failed(_targets, _diagnostics),
    do: {:error, :secure_execution_targets_unavailable}

  defp diagnostics(resources, reason, cancel_required) do
    %{
      "schema" => "serviceradar.secure_execution_failure.v1",
      "reason" => SafeFailureEvidence.code(reason),
      "cancel_required" => cancel_required,
      "execution_id" => resources.execution.id,
      "snapshot_digest" => resources.execution.snapshot_digest
    }
  end

  defp dispatch_after_commit(%Attempt{} = attempt, opts) do
    dispatcher = Keyword.get(opts, :dispatcher, &SecureExecutionCommandDispatcher.dispatch/1)

    case dispatcher.(attempt) do
      {:ok, _outcome} ->
        :ok

      {:error, dispatch_reason} ->
        Logger.warning("authority-contraction cancellation deferred to recovery",
          attempt_id: attempt.id,
          command_id: attempt.command_id,
          reason: SafeFailureEvidence.code(dispatch_reason)
        )

        :ok
    end
  end

  defp transaction(opts, fun) do
    transaction = Keyword.get(opts, :transaction, &Repo.transaction/1)
    transaction.(fun)
  end

  defp rollback(opts, reason) do
    rollback = Keyword.get(opts, :rollback, &Repo.rollback/1)
    rollback.(reason)
  end

  defp attempt_store(opts), do: Keyword.get(opts, :attempt_store, Attempt)

  defp lifecycle_opts(opts, base) do
    case Keyword.get(opts, :secure_lifecycle_actions) do
      nil -> base
      actions -> Keyword.put(base, :actions, actions)
    end
  end
end
