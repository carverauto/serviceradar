defmodule ServiceRadar.Automation.Ansible.CallbackCommandResultCoordinator do
  @moduledoc """
  Replay-safe coordinator for durable callback AWX command results.

  The gateway notification is only an authenticated wake-up signal. Every
  transition is driven from the terminal `AgentCommand` row and its immutable
  callback attempt. Result fields never select a grant, execution, controller,
  agent, credential, or job.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Automation.Ansible.AutomationCallbackCommandAttempt, as: Attempt
  alias ServiceRadar.Automation.Ansible.AutomationExecution
  alias ServiceRadar.Automation.Ansible.AutomationExecutionTarget
  alias ServiceRadar.Automation.Ansible.AutomationOperation
  alias ServiceRadar.Automation.Ansible.CallbackCommandContract
  alias ServiceRadar.Automation.Ansible.CallbackCommandDispatcher
  alias ServiceRadar.Automation.Ansible.Controller
  alias ServiceRadar.Automation.Ansible.ExecutionLifecycle
  alias ServiceRadar.Automation.Ansible.SafeFailureEvidence
  alias ServiceRadar.Automation.Ansible.SecureExecutionLifecycle
  alias ServiceRadar.Automation.CallbackGrants.AshStore, as: GrantStore
  alias ServiceRadar.Automation.CallbackGrants.CanonicalJSON
  alias ServiceRadar.Automation.CallbackGrants.Lifecycle
  alias ServiceRadar.Automation.CallbackGrants.Runtime
  alias ServiceRadar.Edge.AgentCommand
  alias ServiceRadar.Repo

  require Logger

  @actor SystemActor.system(:automation_callback_command_result_coordinator)
  @processing_lease_seconds 30
  @poll_seconds 1
  @command_types [
    "awx.create_callback_credential",
    "awx.fetch_callback_credential",
    "awx.launch_job",
    "awx.fetch_job",
    "awx.list_recent_jobs",
    "awx.fetch_job_host_summaries"
  ]
  @active_job_statuses ~w(new pending waiting running)
  @terminal_job_statuses ~w(successful failed error canceled)

  @spec handle_command_result(map(), keyword()) ::
          {:ok, atom()} | {:error, term()} | :ignored
  def handle_command_result(data, opts \\ [])

  def handle_command_result(data, opts) when is_map(data) and is_list(opts) do
    command_id = value(data, :command_id)
    command_type = value(data, :command_type)
    authenticated_agent_id = value(data, :agent_id)

    if command_type in @command_types do
      with {:ok, command_id} <- uuid(command_id),
           true <- nonempty?(authenticated_agent_id) || {:error, :authenticated_agent_required} do
        process_persisted(command_id, authenticated_agent_id, command_type, opts)
      else
        false -> {:error, :authenticated_agent_required}
        {:error, _reason} = error -> error
      end
    else
      :ignored
    end
  rescue
    exception ->
      Logger.error("callback command result coordination crashed",
        command_id: safe_id(value(data, :command_id)),
        exception: exception.__struct__
      )

      {:error, :callback_result_coordination_unavailable}
  catch
    kind, _reason ->
      Logger.error("callback command result coordination threw",
        command_id: safe_id(value(data, :command_id)),
        failure_kind: kind
      )

      {:error, :callback_result_coordination_unavailable}
  end

  def handle_command_result(_data, _opts), do: {:error, :invalid_callback_command_result}

  @doc """
  Processes one already-persisted command. Recovery callers pass the agent and
  type read from that row; live callers pass authenticated gateway provenance.
  """
  @spec process_persisted(binary(), binary(), binary(), keyword()) ::
          {:ok, atom()} | {:error, term()}
  def process_persisted(command_id, authenticated_agent_id, reported_command_type, opts \\ [])

  def process_persisted(command_id, authenticated_agent_id, reported_command_type, opts)
      when is_binary(command_id) and is_binary(authenticated_agent_id) and
             is_binary(reported_command_type) and
             is_list(opts) do
    now = now(opts)

    with {:ok, bundle} <- load_bundle(command_id, opts),
         :ok <-
           exact_authenticated_provenance(bundle, authenticated_agent_id, reported_command_type),
         :ok <- terminal_command(bundle.command) do
      process_terminal_bundle(bundle, now, opts)
    else
      {:error, _reason} = error -> error
    end
  rescue
    exception ->
      Logger.error("persisted callback result processing crashed",
        command_id: safe_id(command_id),
        exception: exception.__struct__
      )

      {:error, :callback_result_coordination_unavailable}
  catch
    kind, _reason ->
      Logger.error("persisted callback result processing threw",
        command_id: safe_id(command_id),
        failure_kind: kind
      )

      {:error, :callback_result_coordination_unavailable}
  end

  def process_persisted(_command_id, _agent_id, _command_type, _opts),
    do: {:error, :invalid_callback_command_result}

  @doc """
  Converts an expired active transport into a read-only reconciliation step.

  This is the only recovery path for ambiguous credential creation and job
  launch. It never retransmits either side-effect command blindly.
  """
  @spec reconcile_transport_ambiguity(Attempt.t(), keyword()) ::
          {:ok, atom()} | {:error, term()}
  def reconcile_transport_ambiguity(attempt, opts \\ [])

  def reconcile_transport_ambiguity(%Attempt{} = attempt, opts) do
    now = now(opts)

    with {:ok, bundle} <- load_bundle(attempt.command_id, opts),
         true <- same_id?(bundle.attempt.id, attempt.id) || {:error, :callback_attempt_changed},
         {:ok, claimed, token} <- claim_processing(bundle.attempt, now, opts) do
      bundle = %{bundle | attempt: claimed}
      reconcile_claimed_transport(bundle, token, now, opts)
    else
      false -> {:error, :callback_attempt_changed}
      {:error, _reason} = error -> error
    end
  end

  def reconcile_transport_ambiguity(_attempt, _opts),
    do: {:error, :invalid_callback_command_attempt}

  defp load_bundle(command_id, opts) do
    loader = Keyword.get(opts, :bundle_loader, &load_persisted_bundle/1)
    loader.(command_id)
  end

  defp load_persisted_bundle(command_id) do
    with {:ok, %AgentCommand{} = command} <-
           required(AgentCommand.get_by_id(command_id, actor: @actor)),
         {:ok, %Attempt{} = attempt} <-
           required(Attempt.get_by_command_id(command_id, actor: @actor)),
         {:ok, %AutomationOperation{} = operation} <-
           required(AutomationOperation.get_by_id(attempt.operation_id, actor: @actor)),
         {:ok, %AutomationExecution{} = execution} <-
           required(AutomationExecution.get_by_id(attempt.execution_id, actor: @actor)),
         {:ok, targets} <-
           AutomationExecutionTarget.list_for_execution(execution.id, actor: @actor),
         true <- targets != [] || {:error, :callback_execution_targets_missing},
         {:ok, %Controller{} = controller} <-
           required(Controller.get_by_id(attempt.controller_id, actor: @actor)),
         {:ok, grant} <- GrantStore.fetch(attempt.grant_id, nil) do
      {:ok,
       %{
         command: command,
         attempt: attempt,
         operation: operation,
         execution: execution,
         targets: targets,
         controller: controller,
         grant: grant
       }}
    else
      false -> {:error, :callback_execution_targets_missing}
      {:error, _reason} = error -> error
    end
  end

  defp exact_authenticated_provenance(bundle, authenticated_agent_id, reported_type) do
    cond do
      bundle.command.agent_id != authenticated_agent_id ->
        {:error, :callback_result_authenticated_agent_mismatch}

      bundle.attempt.dispatch_agent_id != authenticated_agent_id ->
        {:error, :callback_result_attempt_agent_mismatch}

      bundle.command.command_type != reported_type ->
        {:error, :callback_result_reported_type_mismatch}

      true ->
        :ok
    end
  end

  defp terminal_command(%AgentCommand{status: status})
       when status in [:completed, :failed, :expired, :canceled, :offline], do: :ok

  defp terminal_command(_command), do: {:error, :callback_command_not_terminal}

  defp process_terminal_bundle(bundle, now, opts) do
    case attempt_state(bundle.attempt) do
      :terminal ->
        with {:ok, request} <- rebuild_request(bundle),
             :ok <- exact_persisted_contract(bundle, request) do
          {:ok, :already_processed}
        end

      :active ->
        with {:ok, claimed, lease_token} <- claim_processing(bundle.attempt, now, opts) do
          bundle
          |> Map.put(:attempt, claimed)
          |> process_claimed_terminal(lease_token, now, opts)
        end
    end
  end

  defp process_claimed_terminal(bundle, lease_token, now, opts) do
    case result_digest(bundle.command) do
      {:ok, result_digest} ->
        case rebuild_and_validate(bundle) do
          {:ok, request} ->
            case process_claimed(bundle, request, lease_token, result_digest, now, opts) do
              {:ok, next_attempt, outcome} ->
                dispatch_after_commit(next_attempt, opts)
                {:ok, outcome}

              {:error, _reason} = error ->
                error
            end

          {:error, reason} ->
            finish_fail_closed(bundle, lease_token, result_digest, reason, now, opts)
        end

      {:error, reason} ->
        finish_fail_closed(bundle, lease_token, nil, reason, now, opts)
    end
  end

  defp reconcile_claimed_transport(bundle, token, now, opts) do
    case rebuild_and_validate(bundle) do
      {:ok, _request} ->
        with {:ok, next_attrs, outcome} <- reconciliation_attempt_attrs(bundle, now),
             {:ok, next} <-
               ambiguous_with_next(bundle.attempt, token, nil, outcome, next_attrs, now),
             :ok <- dispatch_after_commit(next, opts) do
          {:ok, outcome}
        end

      {:error, reason} ->
        finish_fail_closed(bundle, token, nil, reason, now, opts)
    end
  end

  defp rebuild_and_validate(bundle) do
    with {:ok, request} <- rebuild_request(bundle),
         :ok <- exact_persisted_contract(bundle, request) do
      {:ok, request}
    end
  end

  defp finish_fail_closed(bundle, token, digest, reason, now, opts) do
    case fail_closed(bundle, token, digest, reason, now, opts) do
      {:ok, nil, outcome} -> {:ok, outcome}
      {:error, _reason} = error -> error
    end
  end

  defp attempt_state(%Attempt{state: state}) when state in [:succeeded, :failed, :ambiguous],
    do: :terminal

  defp attempt_state(%Attempt{}), do: :active

  defp claim_processing(attempt, now, opts) do
    lease_token = Ecto.UUID.generate()
    lease_expires_at = DateTime.add(now, @processing_lease_seconds, :second)
    claimer = Keyword.get(opts, :processing_claimer, &claim_processing_persisted/4)

    case claimer.(attempt, lease_token, lease_expires_at, now) do
      {:ok, claimed} -> {:ok, claimed, lease_token}
      {:error, reason} -> {:error, {:callback_result_processing_claim_failed, reason}}
    end
  end

  defp claim_processing_persisted(attempt, lease_token, lease_expires_at, now) do
    Attempt.mark_processing(
      attempt,
      %{
        lease_token: lease_token,
        lease_expires_at: lease_expires_at,
        now: now,
        processing_started_at: now
      },
      actor: @actor
    )
  end

  defp rebuild_request(%{attempt: %Attempt{stage: :create_credential}} = bundle) do
    CallbackCommandContract.create_credential_request(
      bundle.execution,
      bundle.grant.awx_scope_snapshot,
      bundle.grant.launch_envelope_ref
    )
  end

  defp rebuild_request(%{attempt: %Attempt{stage: :fetch_credential}} = bundle) do
    CallbackCommandContract.credential_lookup_request(
      bundle.execution,
      bundle.grant.awx_scope_snapshot
    )
  end

  defp rebuild_request(%{attempt: %Attempt{stage: :launch_job}} = bundle) do
    CallbackCommandContract.launch_request(
      bundle.operation,
      bundle.execution,
      bundle.attempt.expected_credential_id
    )
  end

  defp rebuild_request(%{attempt: %Attempt{stage: :fetch_job}} = bundle),
    do: CallbackCommandContract.fetch_job_request(bundle.attempt.expected_job_id)

  defp rebuild_request(%{attempt: %Attempt{stage: :fetch_host_summaries}} = bundle) do
    CallbackCommandContract.host_summaries_request(
      bundle.attempt.expected_job_id,
      length(bundle.targets)
    )
  end

  defp rebuild_request(%{attempt: %Attempt{stage: :list_recent_jobs}} = bundle),
    do:
      CallbackCommandContract.recent_jobs_request(
        bundle.execution,
        bundle.attempt.reconcile_after
      )

  defp rebuild_request(_bundle), do: {:error, :callback_command_stage_not_processable}

  defp exact_persisted_contract(bundle, request) do
    checks = [
      same_id?(bundle.command.id, bundle.attempt.command_id),
      bundle.command.command_type == bundle.attempt.command_type,
      bundle.command.agent_id == bundle.attempt.dispatch_agent_id,
      same_id?(bundle.execution.id, bundle.attempt.execution_id),
      same_id?(bundle.operation.id, bundle.attempt.operation_id),
      same_id?(bundle.controller.id, bundle.attempt.controller_id),
      same_id?(value(bundle.grant, :id), bundle.attempt.grant_id),
      CallbackCommandContract.request_matches?(bundle.attempt, request),
      CallbackCommandContract.context_matches?(
        bundle.attempt,
        bundle.execution,
        bundle.command.context || %{}
      ),
      CallbackCommandContract.persisted_payload_matches?(
        bundle.attempt,
        bundle.execution,
        bundle.controller,
        request,
        bundle.command.payload || %{}
      )
    ]

    if Enum.all?(checks), do: :ok, else: {:error, :callback_command_correlation_mismatch}
  end

  defp process_claimed(bundle, request, lease_token, result_digest, now, opts) do
    if successful_command?(bundle.command) do
      case process_success(bundle, request, lease_token, result_digest, now, opts) do
        {:ok, _next, _outcome} = success -> success
        {:error, reason} -> fail_closed(bundle, lease_token, result_digest, reason, now, opts)
      end
    else
      process_command_failure(bundle, lease_token, result_digest, now, opts)
    end
  end

  defp process_command_failure(bundle, token, digest, now, opts) do
    case reconciliation_attempt_attrs(bundle, now) do
      {:ok, next_attrs, outcome} ->
        with {:ok, next} <-
               ambiguous_with_next(bundle.attempt, token, digest, outcome, next_attrs, now) do
          {:ok, next, outcome}
        end

      {:error, :callback_command_not_reconcilable} ->
        fail_closed(
          bundle,
          token,
          digest,
          {:callback_agent_command_failed, bundle.command.status},
          now,
          opts
        )

      {:error, reason} ->
        fail_closed(bundle, token, digest, reason, now, opts)
    end
  end

  defp process_success(
         %{attempt: %Attempt{stage: :create_credential}} = bundle,
         _request,
         token,
         digest,
         now,
         opts
       ) do
    with {:ok, credential_id} <- exact_create_result(bundle),
         {:ok, _bound} <-
           lifecycle(opts).bind_credential(
             bundle.attempt.grant_id,
             credential_id,
             lifecycle_opts!(opts)
           ),
         {:ok, request} <-
           CallbackCommandContract.launch_request(
             bundle.operation,
             bundle.execution,
             credential_id
           ),
         {:ok, next_attrs} <-
           next_attempt_attrs(bundle, request, now,
             stage: :launch_job,
             purpose: :accepted_job_proof,
             command_type: "awx.launch_job",
             expected_credential_id: credential_id
           ),
         {:ok, next} <-
           complete_with_next(bundle.attempt, token, digest, :credential_bound, next_attrs, now) do
      {:ok, next, :credential_bound}
    end
  end

  defp process_success(
         %{attempt: %Attempt{stage: :launch_job}} = bundle,
         _request,
         token,
         digest,
         now,
         opts
       ) do
    with {:ok, job_id} <- exact_launch_result(bundle),
         {:ok, binding} <- Lifecycle.pending_job_binding(bundle.grant, job_id),
         {:ok, _bound} <-
           lifecycle(opts).bind_job(bundle.attempt.grant_id, binding, lifecycle_opts!(opts)),
         {:ok, request} <- CallbackCommandContract.fetch_job_request(job_id),
         {:ok, next_attrs} <-
           next_attempt_attrs(bundle, request, now,
             stage: :fetch_job,
             purpose: :accepted_job_proof,
             command_type: "awx.fetch_job",
             expected_credential_id: bundle.attempt.expected_credential_id,
             expected_job_id: job_id
           ),
         {:ok, next} <-
           complete_with_next(bundle.attempt, token, digest, :job_bound_pending, next_attrs, now) do
      {:ok, next, :job_bound_pending}
    end
  end

  defp process_success(
         %{attempt: %Attempt{stage: :fetch_credential}} = bundle,
         _request,
         token,
         digest,
         now,
         opts
       ) do
    with {:ok, result} <- exact_credential_lookup_result(bundle) do
      if result.found? do
        with {:ok, _bound} <-
               lifecycle(opts).bind_credential(
                 bundle.attempt.grant_id,
                 result.credential_id,
                 lifecycle_opts!(opts)
               ),
             {:ok, request} <-
               CallbackCommandContract.launch_request(
                 bundle.operation,
                 bundle.execution,
                 result.credential_id
               ),
             {:ok, next_attrs} <-
               next_attempt_attrs(bundle, request, now,
                 stage: :launch_job,
                 purpose: :accepted_job_proof,
                 command_type: "awx.launch_job",
                 expected_credential_id: result.credential_id
               ),
             {:ok, next} <-
               complete_with_next(
                 bundle.attempt,
                 token,
                 digest,
                 :credential_reconciled,
                 next_attrs,
                 now
               ) do
          {:ok, next, :credential_reconciled}
        end
      else
        schedule_credential_lookup_poll(bundle, token, digest, now)
      end
    end
  end

  defp process_success(
         %{attempt: %Attempt{stage: :fetch_job, purpose: :accepted_job_proof}} = bundle,
         _request,
         token,
         digest,
         now,
         opts
       ) do
    with {:ok, job} <- exact_fetch_job_result(bundle),
         :ok <- active_job(job),
         {:ok, accepted} <-
           ExecutionLifecycle.accepted_job_snapshot(bundle.execution, bundle.controller.id, job,
             expected_ephemeral_credential_id: bundle.attempt.expected_credential_id
           ),
         {:ok, execution} <-
           ExecutionLifecycle.bind_accepted_job(bundle.execution, bundle.controller.id, job,
             expected_ephemeral_credential_id: bundle.attempt.expected_credential_id,
             targets: bundle.targets
           ),
         {:ok, grant} <- GrantStore.fetch(bundle.attempt.grant_id, nil),
         {:ok, binding} <- Lifecycle.job_binding_from_accepted(grant, accepted),
         {:ok, _bound} <-
           lifecycle(opts).bind_job(bundle.attempt.grant_id, binding, lifecycle_opts!(opts)),
         bundle = %{bundle | execution: execution, grant: grant},
         {:ok, request} <-
           CallbackCommandContract.host_summaries_request(
             bundle.attempt.expected_job_id,
             length(bundle.targets)
           ),
         {:ok, next_attrs} <-
           next_attempt_attrs(bundle, request, now,
             stage: :fetch_host_summaries,
             purpose: :host_scope_proof,
             command_type: "awx.fetch_job_host_summaries",
             expected_credential_id: bundle.attempt.expected_credential_id,
             expected_job_id: bundle.attempt.expected_job_id
           ),
         {:ok, next} <-
           complete_with_next(
             bundle.attempt,
             token,
             digest,
             :accepted_job_verified,
             next_attrs,
             now
           ) do
      {:ok, next, :accepted_job_verified}
    end
  end

  defp process_success(
         %{attempt: %Attempt{stage: :fetch_job, purpose: :scope_poll}} = bundle,
         _request,
         token,
         digest,
         now,
         opts
       ) do
    with {:ok, job} <- exact_fetch_job_result(bundle) do
      case normalized_job_status(job) do
        status when status in @active_job_statuses ->
          with {:ok, request} <-
                 CallbackCommandContract.host_summaries_request(
                   bundle.attempt.expected_job_id,
                   length(bundle.targets)
                 ),
               {:ok, next_attrs} <-
                 next_attempt_attrs(bundle, request, now,
                   stage: :fetch_host_summaries,
                   purpose: :host_scope_proof,
                   command_type: "awx.fetch_job_host_summaries",
                   expected_credential_id: bundle.attempt.expected_credential_id,
                   expected_job_id: bundle.attempt.expected_job_id
                 ),
               {:ok, next} <-
                 complete_with_next(
                   bundle.attempt,
                   token,
                   digest,
                   :job_still_active,
                   next_attrs,
                   now
                 ) do
            {:ok, next, :job_still_active}
          end

        status when status in @terminal_job_statuses ->
          with {:ok, _grant} <-
                 lifecycle(opts).job_terminal(
                   bundle.attempt.grant_id,
                   status,
                   lifecycle_opts!(opts)
                 ),
               {:ok, _attempt} <-
                 complete_without_next(bundle.attempt, token, digest, :job_terminal, now) do
            {:ok, nil, :job_terminal}
          end

        _status ->
          {:error, :unrecognized_callback_job_status}
      end
    end
  end

  defp process_success(
         %{attempt: %Attempt{stage: :fetch_host_summaries, purpose: :host_scope_proof}} = bundle,
         _request,
         token,
         digest,
         now,
         opts
       ) do
    with {:ok, summaries} <- exact_summary_result(bundle) do
      case ExecutionLifecycle.classify_host_scope(
             bundle.execution,
             bundle.targets,
             bundle.controller.id,
             bundle.attempt.expected_job_id,
             summaries
           ) do
        {:ok, :exact} ->
          activate_exact_scope(bundle, summaries, token, digest, now, opts)

        {:retry, :host_scope_incomplete} ->
          schedule_scope_poll(bundle, token, digest, now)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp process_success(
         %{attempt: %Attempt{stage: :fetch_job, purpose: :terminal_poll}} = bundle,
         _request,
         token,
         digest,
         now,
         _opts
       ) do
    with {:ok, job} <- exact_fetch_job_result(bundle),
         :ok <-
           SecureExecutionLifecycle.validate_bound_job(
             bundle.execution,
             bundle.controller.id,
             job
           ),
         {:ok, state} <- SecureExecutionLifecycle.job_state(job) do
      case state do
        :active -> schedule_terminal_poll(bundle, token, digest, now)
        _terminal -> schedule_terminal_confirmation(bundle, job, token, digest, now)
      end
    end
  end

  defp process_success(
         %{attempt: %Attempt{stage: :fetch_host_summaries, purpose: :terminal_confirmation}} =
           bundle,
         _request,
         token,
         digest,
         now,
         opts
       ) do
    with {:ok, summaries} <- exact_summary_result(bundle),
         true <-
           CallbackCommandContract.terminal_job_snapshot?(bundle.attempt.terminal_job_snapshot) ||
             {:error, :terminal_job_evidence_missing} do
      case ExecutionLifecycle.classify_host_scope(
             bundle.execution,
             bundle.targets,
             bundle.controller.id,
             bundle.attempt.expected_job_id,
             summaries
           ) do
        {:ok, :exact} ->
          persist_terminal_result(bundle, summaries, token, digest, now, opts)

        {:retry, :host_scope_incomplete} ->
          schedule_terminal_summary_poll(bundle, token, digest, now)

        {:error, reason} ->
          {:error, reason}
      end
    else
      false -> {:error, :terminal_job_evidence_missing}
      {:error, _reason} = error -> error
    end
  end

  defp process_success(
         %{attempt: %Attempt{stage: :list_recent_jobs}} = bundle,
         request,
         token,
         digest,
         now,
         opts
       ) do
    with {:ok, result} <- exact_recent_jobs_result(bundle, request),
         {:ok, candidate} <- exact_reconciled_job_candidate(bundle, result) do
      case candidate do
        nil ->
          schedule_recent_jobs_poll(bundle, request, token, digest, now)

        %{job_id: job_id} ->
          with {:ok, binding} <- Lifecycle.pending_job_binding(bundle.grant, job_id),
               {:ok, _bound} <-
                 lifecycle(opts).bind_job(
                   bundle.attempt.grant_id,
                   binding,
                   lifecycle_opts!(opts)
                 ),
               {:ok, fetch_request} <- CallbackCommandContract.fetch_job_request(job_id),
               {:ok, next_attrs} <-
                 next_attempt_attrs(bundle, fetch_request, now,
                   stage: :fetch_job,
                   purpose: :accepted_job_proof,
                   command_type: "awx.fetch_job",
                   expected_credential_id: value(bundle.grant, :ephemeral_credential_id),
                   expected_job_id: job_id
                 ),
               {:ok, next} <-
                 complete_with_next(
                   bundle.attempt,
                   token,
                   digest,
                   :launch_reconciled,
                   next_attrs,
                   now
                 ) do
            {:ok, next, :launch_reconciled}
          end
      end
    end
  end

  defp process_success(_bundle, _request, _token, _digest, _now, _opts),
    do: {:error, :callback_command_stage_not_processable}

  defp activate_exact_scope(bundle, summaries, token, digest, now, opts) do
    next_at = DateTime.add(now, @poll_seconds, :second)

    with :ok <- before_deadline(bundle.attempt, next_at),
         {:ok, request} <-
           CallbackCommandContract.fetch_job_request(bundle.attempt.expected_job_id),
         {:ok, next_attrs} <-
           next_attempt_attrs(bundle, request, now,
             stage: :fetch_job,
             purpose: :terminal_poll,
             command_type: "awx.fetch_job",
             expected_credential_id: bundle.attempt.expected_credential_id,
             expected_job_id: bundle.attempt.expected_job_id,
             next_attempt_at: next_at
           ),
         {:ok, next} <-
           Repo.transaction(fn ->
             with {:ok, scope} <-
                    ExecutionLifecycle.verify_host_scope(
                      bundle.execution,
                      bundle.targets,
                      bundle.controller.id,
                      bundle.attempt.expected_job_id,
                      summaries,
                      execution_lifecycle_opts(opts,
                        mutating?: bundle.operation.mutating
                      )
                    ),
                  {:ok, grant} <- GrantStore.fetch(bundle.attempt.grant_id, nil),
                  {:ok, binding} <-
                    Lifecycle.job_binding_from_accepted(
                      grant,
                      scope.execution.accepted_job_snapshot
                    ),
                  {:ok, _activated} <-
                    lifecycle(opts).activate(
                      bundle.attempt.grant_id,
                      binding,
                      lifecycle_opts!(opts)
                    ),
                  {:ok, _running} <-
                    SecureExecutionLifecycle.mark_running(
                      bundle.operation,
                      scope.execution,
                      secure_lifecycle_opts(opts)
                    ),
                  {:ok, _attempt} <-
                    Attempt.mark_succeeded(
                      bundle.attempt,
                      %{
                        lease_token: token,
                        processed_at: now,
                        outcome_code: "scope_verified_and_activated",
                        result_digest: digest
                      },
                      actor: @actor
                    ),
                  {:ok, next} <- Attempt.create_planned(next_attrs, actor: @actor) do
               next
             else
               {:error, reason} -> Repo.rollback(reason)
             end
           end) do
      _ = delete_activated_credential(bundle.attempt.grant_id, opts)
      {:ok, next, :scope_verified_and_activated}
    end
  end

  defp schedule_terminal_poll(bundle, token, digest, now) do
    next_at = DateTime.add(now, @poll_seconds, :second)

    with :ok <- before_deadline(bundle.attempt, next_at),
         {:ok, request} <-
           CallbackCommandContract.fetch_job_request(bundle.attempt.expected_job_id),
         {:ok, next_attrs} <-
           next_attempt_attrs(bundle, request, now,
             stage: :fetch_job,
             purpose: :terminal_poll,
             command_type: "awx.fetch_job",
             expected_credential_id: bundle.attempt.expected_credential_id,
             expected_job_id: bundle.attempt.expected_job_id,
             next_attempt_at: next_at
           ),
         {:ok, next} <-
           complete_with_next(
             bundle.attempt,
             token,
             digest,
             :job_still_active,
             next_attrs,
             now
           ) do
      {:ok, next, :job_still_active}
    end
  end

  defp schedule_terminal_confirmation(bundle, job, token, digest, now) do
    with {:ok, request} <-
           CallbackCommandContract.host_summaries_request(
             bundle.attempt.expected_job_id,
             length(bundle.targets)
           ),
         {:ok, next_attrs} <-
           next_attempt_attrs(bundle, request, now,
             stage: :fetch_host_summaries,
             purpose: :terminal_confirmation,
             command_type: "awx.fetch_job_host_summaries",
             expected_credential_id: bundle.attempt.expected_credential_id,
             expected_job_id: bundle.attempt.expected_job_id,
             terminal_job_snapshot: job
           ),
         {:ok, next} <-
           complete_with_next(
             bundle.attempt,
             token,
             digest,
             :terminal_job_observed,
             next_attrs,
             now
           ) do
      {:ok, next, :terminal_job_observed}
    end
  end

  defp schedule_terminal_summary_poll(bundle, token, digest, now) do
    case reconciliation_attempt_attrs(bundle, now) do
      {:ok, next_attrs, _outcome} ->
        with {:ok, next} <-
               complete_with_next(
                 bundle.attempt,
                 token,
                 digest,
                 :terminal_host_summaries_incomplete,
                 next_attrs,
                 now
               ) do
          {:ok, next, :terminal_host_summaries_incomplete}
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp persist_terminal_result(bundle, summaries, token, digest, now, opts) do
    status = normalized_job_status(bundle.attempt.terminal_job_snapshot)

    with {:ok, _grant} <-
           lifecycle(opts).job_terminal(
             bundle.attempt.grant_id,
             status,
             lifecycle_opts!(opts)
           ),
         {:ok, _terminal} <-
           Repo.transaction(fn ->
             with {:ok, terminal} <-
                    SecureExecutionLifecycle.complete_terminal(
                      bundle.operation,
                      bundle.execution,
                      bundle.targets,
                      bundle.controller.id,
                      bundle.attempt.terminal_job_snapshot,
                      summaries,
                      secure_lifecycle_opts(opts)
                    ),
                  {:ok, _attempt} <-
                    Attempt.mark_succeeded(
                      bundle.attempt,
                      %{
                        lease_token: token,
                        processed_at: now,
                        outcome_code: "terminal_state_persisted",
                        result_digest: digest
                      },
                      actor: @actor
                    ) do
               terminal
             else
               {:error, reason} -> Repo.rollback(reason)
             end
           end) do
      {:ok, nil, :terminal_state_persisted}
    end
  end

  defp schedule_scope_poll(bundle, token, digest, now) do
    next_at = DateTime.add(now, @poll_seconds, :second)

    with :ok <- before_deadline(bundle.attempt, next_at),
         {:ok, request} <-
           CallbackCommandContract.fetch_job_request(bundle.attempt.expected_job_id),
         {:ok, next_attrs} <-
           next_attempt_attrs(bundle, request, now,
             stage: :fetch_job,
             purpose: :scope_poll,
             command_type: "awx.fetch_job",
             expected_credential_id: bundle.attempt.expected_credential_id,
             expected_job_id: bundle.attempt.expected_job_id,
             next_attempt_at: next_at
           ),
         {:ok, next} <-
           complete_with_next(
             bundle.attempt,
             token,
             digest,
             :host_scope_incomplete,
             next_attrs,
             now
           ) do
      {:ok, next, :host_scope_incomplete}
    end
  end

  defp schedule_credential_lookup_poll(bundle, token, digest, now) do
    next_at = DateTime.add(now, @poll_seconds, :second)

    with :ok <- before_deadline(bundle.attempt, next_at),
         {:ok, request} <-
           CallbackCommandContract.credential_lookup_request(
             bundle.execution,
             bundle.grant.awx_scope_snapshot
           ),
         {:ok, next_attrs} <-
           next_attempt_attrs(bundle, request, now,
             stage: :fetch_credential,
             purpose: :credential_reconciliation,
             command_type: "awx.fetch_callback_credential",
             next_attempt_at: next_at
           ),
         {:ok, next} <-
           complete_with_next(
             bundle.attempt,
             token,
             digest,
             :credential_not_visible_during_reconciliation,
             next_attrs,
             now
           ) do
      {:ok, next, :credential_not_visible_during_reconciliation}
    end
  end

  defp schedule_recent_jobs_poll(bundle, request, token, digest, now) do
    next_at = DateTime.add(now, @poll_seconds, :second)

    with :ok <- before_deadline(bundle.attempt, next_at),
         {:ok, next_attrs} <-
           next_attempt_attrs(bundle, request, now,
             stage: :list_recent_jobs,
             purpose: :launch_reconciliation,
             command_type: "awx.list_recent_jobs",
             expected_credential_id: value(bundle.grant, :ephemeral_credential_id),
             reconcile_after: bundle.attempt.reconcile_after,
             next_attempt_at: next_at
           ),
         {:ok, next} <-
           complete_with_next(
             bundle.attempt,
             token,
             digest,
             :launch_candidate_not_visible,
             next_attrs,
             now
           ) do
      {:ok, next, :launch_candidate_not_visible}
    end
  end

  defp reconciliation_attempt_attrs(%{attempt: %Attempt{stage: :create_credential}} = bundle, now) do
    with {:ok, request} <-
           CallbackCommandContract.credential_lookup_request(
             bundle.execution,
             bundle.grant.awx_scope_snapshot
           ),
         {:ok, attrs} <-
           next_attempt_attrs(bundle, request, now,
             stage: :fetch_credential,
             purpose: :credential_reconciliation,
             command_type: "awx.fetch_callback_credential"
           ) do
      {:ok, attrs, :credential_transport_reconciliation}
    end
  end

  defp reconciliation_attempt_attrs(%{attempt: %Attempt{stage: :launch_job}} = bundle, now) do
    reconcile_after =
      bundle.attempt.dispatched_at || bundle.attempt.inserted_at ||
        DateTime.add(now, -60, :second)

    with {:ok, request} <-
           CallbackCommandContract.recent_jobs_request(bundle.execution, reconcile_after),
         {:ok, attrs} <-
           next_attempt_attrs(bundle, request, now,
             stage: :list_recent_jobs,
             purpose: :launch_reconciliation,
             command_type: "awx.list_recent_jobs",
             expected_credential_id: bundle.attempt.expected_credential_id,
             reconcile_after: reconcile_after
           ) do
      {:ok, attrs, :launch_transport_reconciliation}
    end
  end

  defp reconciliation_attempt_attrs(%{attempt: %Attempt{stage: stage}} = bundle, now)
       when stage in [:fetch_credential, :fetch_job, :list_recent_jobs, :fetch_host_summaries] do
    next_at = DateTime.add(now, @poll_seconds, :second)

    with :ok <- before_deadline(bundle.attempt, next_at),
         {:ok, request} <- rebuild_request(bundle),
         {:ok, attrs} <-
           next_attempt_attrs(bundle, request, now,
             stage: bundle.attempt.stage,
             purpose: bundle.attempt.purpose,
             command_type: bundle.attempt.command_type,
             expected_credential_id: bundle.attempt.expected_credential_id,
             expected_job_id: bundle.attempt.expected_job_id,
             reconcile_after: bundle.attempt.reconcile_after,
             terminal_job_snapshot: bundle.attempt.terminal_job_snapshot,
             next_attempt_at: next_at
           ) do
      {:ok, attrs, :read_only_transport_retry}
    end
  end

  defp reconciliation_attempt_attrs(_bundle, _now),
    do: {:error, :callback_command_not_reconcilable}

  defp exact_create_result(bundle) do
    payload = stringify(bundle.command.result_payload)
    scope = bundle.grant.awx_scope_snapshot || %{}
    expected_name = "sr-callback-#{bundle.execution.id}"

    with :ok <-
           exact_keys(
             payload,
             ~w(verb ok credential_id credential_type_id organization_id credential_name injector_sha256)
           ),
         true <- payload["verb"] == bundle.attempt.command_type,
         true <- payload["ok"] == true,
         credential_id when is_integer(credential_id) and credential_id > 0 <-
           payload["credential_id"],
         true <- payload["credential_type_id"] == value(scope, :callback_credential_type_id),
         true <- payload["organization_id"] == value(scope, :callback_credential_organization_id),
         true <- payload["credential_name"] == expected_name,
         true <- payload["injector_sha256"] == value(scope, :callback_credential_injector_digest) do
      {:ok, credential_id}
    else
      _ -> {:error, :callback_credential_result_mismatch}
    end
  end

  defp exact_credential_lookup_result(bundle) do
    payload = stringify(bundle.command.result_payload)
    expected = bundle.grant.awx_scope_snapshot || %{}

    common_keys =
      ~w(verb ok found credential_type_id organization_id credential_name)

    with true <- payload["found"] in [true, false],
         keys = if(payload["found"], do: ["credential_id" | common_keys], else: common_keys),
         :ok <- exact_keys(payload, keys),
         true <- payload["verb"] == bundle.attempt.command_type,
         true <- payload["ok"] == true,
         true <- payload["credential_type_id"] == value(expected, :callback_credential_type_id),
         true <-
           payload["organization_id"] == value(expected, :callback_credential_organization_id),
         true <- payload["credential_name"] == "sr-callback-#{bundle.execution.id}",
         :ok <- optional_found_credential_id(payload) do
      {:ok, %{found?: payload["found"], credential_id: payload["credential_id"]}}
    else
      _ -> {:error, :callback_credential_lookup_result_mismatch}
    end
  end

  defp exact_recent_jobs_result(bundle, request) do
    payload = stringify(bundle.command.result_payload)

    with :ok <-
           exact_keys(
             payload,
             ~w(verb ok template_id inventory_id created_by_id created_after page_size count truncated jobs)
           ),
         true <- payload["verb"] == bundle.attempt.command_type,
         true <- payload["ok"] == true,
         true <- payload["template_id"] == value(request, :template_id),
         true <- payload["inventory_id"] == value(request, :inventory_id),
         true <- payload["created_by_id"] == value(request, :created_by_id),
         true <- payload["created_after"] == value(request, :created_after),
         true <- payload["page_size"] == value(request, :page_size),
         count when is_integer(count) and count >= 0 <- payload["count"],
         truncated when is_boolean(truncated) <- payload["truncated"],
         jobs when is_list(jobs) <- payload["jobs"],
         true <-
           (truncated and count >= length(jobs)) or
             (not truncated and count == length(jobs)),
         true <- length(jobs) <= value(request, :page_size) do
      {:ok, %{jobs: jobs, count: count, truncated?: truncated}}
    else
      _ -> {:error, :callback_recent_jobs_result_mismatch}
    end
  end

  defp exact_reconciled_job_candidate(_bundle, %{truncated?: true}),
    do: {:error, :callback_recent_jobs_truncated}

  defp exact_reconciled_job_candidate(bundle, %{jobs: jobs}) do
    candidates =
      Enum.reduce(jobs, [], fn job, acc ->
        with :ok <- active_job(job),
             {:ok, snapshot} <-
               ExecutionLifecycle.accepted_job_snapshot(
                 bundle.execution,
                 bundle.controller.id,
                 job,
                 expected_ephemeral_credential_id: value(bundle.grant, :ephemeral_credential_id)
               ) do
          [%{job: job, job_id: snapshot["awx_job_id"]} | acc]
        else
          _ -> acc
        end
      end)

    case candidates do
      [] -> {:ok, nil}
      [candidate] -> {:ok, candidate}
      _ -> {:error, :callback_launch_reconciliation_ambiguous}
    end
  end

  defp optional_found_credential_id(%{"found" => true, "credential_id" => id})
       when is_integer(id) and id > 0, do: :ok

  defp optional_found_credential_id(%{"found" => false}), do: :ok
  defp optional_found_credential_id(_payload), do: {:error, :invalid_reconciled_credential_id}

  defp exact_launch_result(bundle) do
    payload = stringify(bundle.command.result_payload)

    with :ok <- exact_keys(payload, ~w(verb ok template_id job)),
         true <- payload["verb"] == bundle.attempt.command_type,
         true <- payload["ok"] == true,
         true <- payload["template_id"] == bundle.execution.job_template_id,
         job when is_map(job) <- payload["job"],
         job_id when is_integer(job_id) and job_id > 0 <- value(job, :id) || value(job, :job) do
      {:ok, job_id}
    else
      _ -> {:error, :callback_launch_result_mismatch}
    end
  end

  defp exact_fetch_job_result(bundle) do
    payload = stringify(bundle.command.result_payload)

    with :ok <- exact_keys(payload, ~w(verb ok job_id job)),
         true <- payload["verb"] == bundle.attempt.command_type,
         true <- payload["ok"] == true,
         true <- payload["job_id"] == bundle.attempt.expected_job_id,
         job when is_map(job) <- payload["job"],
         true <- (value(job, :id) || value(job, :job)) == bundle.attempt.expected_job_id do
      {:ok, job}
    else
      _ -> {:error, :callback_fetch_job_result_mismatch}
    end
  end

  defp exact_summary_result(bundle) do
    payload = stringify(bundle.command.result_payload)

    with :ok <- exact_keys(payload, ~w(verb ok job_id count summaries)),
         true <- payload["verb"] == bundle.attempt.command_type,
         true <- payload["ok"] == true,
         true <- payload["job_id"] == bundle.attempt.expected_job_id,
         count when is_integer(count) and count >= 0 <- payload["count"],
         summaries when is_list(summaries) <- payload["summaries"],
         true <- count == length(summaries),
         true <- count <= length(bundle.targets) do
      {:ok, summaries}
    else
      _ -> {:error, :callback_host_summary_result_mismatch}
    end
  end

  defp successful_command?(%AgentCommand{status: :completed, result_payload: payload})
       when is_map(payload),
       do: value(payload, :ok) == true

  defp successful_command?(_command), do: false

  defp active_job(job) do
    if normalized_job_status(job) in @active_job_statuses,
      do: :ok,
      else: {:error, :callback_job_not_active}
  end

  defp normalized_job_status(job) do
    job |> value(:status) |> to_string() |> String.trim() |> String.downcase()
  end

  defp next_attempt_attrs(bundle, request, now, opts) do
    next_at = Keyword.get(opts, :next_attempt_at, now)

    with :ok <- before_deadline(bundle.attempt, next_at) do
      CallbackCommandContract.build_attempt(
        %{
          grant_id: bundle.attempt.grant_id,
          operation_id: bundle.attempt.operation_id,
          execution_id: bundle.attempt.execution_id,
          controller_id: bundle.attempt.controller_id,
          dispatch_agent_id: bundle.attempt.dispatch_agent_id
        },
        bundle.execution,
        request,
        stage: Keyword.fetch!(opts, :stage),
        purpose: Keyword.fetch!(opts, :purpose),
        command_type: Keyword.fetch!(opts, :command_type),
        attempt: next_attempt_number(bundle.attempt, opts),
        expected_credential_id: Keyword.get(opts, :expected_credential_id),
        expected_job_id: Keyword.get(opts, :expected_job_id),
        terminal_job_snapshot: Keyword.get(opts, :terminal_job_snapshot),
        deadline_at: bundle.attempt.deadline_at,
        next_attempt_at: next_at
      )
    end
  end

  defp next_attempt_number(attempt, opts) do
    stage = Keyword.fetch!(opts, :stage)
    purpose = Keyword.fetch!(opts, :purpose)

    case Attempt.list_for_grant(attempt.grant_id, actor: @actor) do
      {:ok, attempts} ->
        attempts
        |> Enum.filter(&(&1.stage == stage and &1.purpose == purpose))
        |> Enum.map(& &1.attempt)
        |> Enum.max(fn -> 0 end)
        |> Kernel.+(1)

      {:error, _reason} ->
        attempt.attempt + 1
    end
  end

  defp complete_with_next(attempt, token, result_digest, outcome, next_attrs, now) do
    Repo.transaction(fn ->
      with {:ok, _completed} <-
             Attempt.mark_succeeded(
               attempt,
               %{
                 lease_token: token,
                 processed_at: now,
                 outcome_code: Atom.to_string(outcome),
                 result_digest: result_digest
               },
               actor: @actor
             ),
           {:ok, next} <- Attempt.create_planned(next_attrs, actor: @actor) do
        next
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp complete_without_next(attempt, token, result_digest, outcome, now) do
    Attempt.mark_succeeded(
      attempt,
      %{
        lease_token: token,
        processed_at: now,
        outcome_code: Atom.to_string(outcome),
        result_digest: result_digest
      },
      actor: @actor
    )
  end

  defp ambiguous_with_next(attempt, token, result_digest, outcome, next_attrs, now) do
    Repo.transaction(fn ->
      with {:ok, _ambiguous} <-
             Attempt.mark_ambiguous(
               attempt,
               %{
                 lease_token: token,
                 processed_at: now,
                 outcome_code: Atom.to_string(outcome),
                 last_error_code: Atom.to_string(outcome),
                 result_digest: result_digest
               },
               actor: @actor
             ),
           {:ok, next} <- Attempt.create_planned(next_attrs, actor: @actor) do
        next
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp fail_closed(bundle, token, result_digest, reason, now, opts) do
    revoke_result =
      lifecycle(opts).revoke(bundle.attempt.grant_id, reason, lifecycle_opts!(opts))

    lifecycle_result = fail_postactivation_execution(bundle, reason, opts)

    action =
      if callback_authority_removed?(revoke_result) and lifecycle_result == :ok,
        do: :mark_failed,
        else: :mark_ambiguous

    outcome =
      if action == :mark_failed, do: "revoked_before_cleanup", else: "revocation_unconfirmed"

    attrs = %{
      lease_token: token,
      processed_at: now,
      outcome_code: outcome,
      last_error_code: error_code(reason),
      result_digest: result_digest
    }

    case apply(Attempt, action, [bundle.attempt, attrs, [actor: @actor]]) do
      {:ok, _attempt} ->
        terminal_outcome =
          if action == :mark_failed, do: :revoked_before_cleanup, else: :revocation_unconfirmed

        {:ok, nil, terminal_outcome}

      {:error, mark_reason} ->
        {:error, {:callback_attempt_terminal_update_failed, mark_reason}}
    end
  end

  defp fail_postactivation_execution(
         %{attempt: %Attempt{purpose: purpose}} = bundle,
         reason,
         opts
       )
       when purpose in [:terminal_poll, :terminal_confirmation] do
    case SecureExecutionLifecycle.fail_closed(
           bundle.operation,
           bundle.execution,
           bundle.targets,
           :cancel_failed,
           reason,
           Keyword.put(secure_lifecycle_opts(opts), :cancel_required, true)
         ) do
      {:ok, _result} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp fail_postactivation_execution(_bundle, _reason, _opts), do: :ok

  defp callback_authority_removed?({:ok, _grant}), do: true

  defp callback_authority_removed?({:error, {:grant_already_terminal, state}})
       when state in [:revoked, :expired],
       do: true

  defp callback_authority_removed?(_result), do: false

  defp dispatch_after_commit(nil, _opts), do: :ok

  defp dispatch_after_commit(%Attempt{} = attempt, opts) do
    dispatcher = Keyword.get(opts, :dispatcher, &CallbackCommandDispatcher.dispatch/1)

    case dispatcher.(attempt) do
      {:ok, _outcome} ->
        :ok

      {:error, reason} ->
        Logger.warning("callback follow-up command deferred to recovery",
          attempt_id: attempt.id,
          command_id: attempt.command_id,
          reason: error_code(reason)
        )

        :ok
    end
  end

  defp delete_activated_credential(grant_id, opts) do
    case Keyword.get(opts, :delete_activated) do
      fun when is_function(fun, 1) -> fun.(grant_id)
      _ -> Runtime.delete_activated_credential(grant_id)
    end
  end

  defp lifecycle(opts), do: Keyword.get(opts, :lifecycle, Lifecycle)

  defp execution_lifecycle_opts(opts, base) do
    case Keyword.get(opts, :execution_lifecycle_actions) do
      nil -> base
      actions -> Keyword.put(base, :actions, actions)
    end
  end

  defp secure_lifecycle_opts(opts) do
    case Keyword.get(opts, :secure_lifecycle_actions) do
      nil -> []
      actions -> [actions: actions]
    end
  end

  defp lifecycle_opts!(opts) do
    case Keyword.fetch(opts, :lifecycle_opts) do
      {:ok, lifecycle_opts} when is_list(lifecycle_opts) ->
        lifecycle_opts

      _ ->
        case Runtime.lifecycle_opts() do
          {:ok, lifecycle_opts} -> lifecycle_opts
          {:error, reason} -> throw({:callback_lifecycle_unavailable, reason})
        end
    end
  end

  defp result_digest(%AgentCommand{result_payload: payload}) when is_map(payload),
    do: CanonicalJSON.digest(payload)

  defp result_digest(_command), do: CanonicalJSON.digest(%{})

  defp before_deadline(attempt, datetime) do
    if DateTime.before?(datetime, attempt.deadline_at),
      do: :ok,
      else: {:error, :callback_command_deadline_elapsed}
  end

  defp exact_keys(map, keys) when is_map(map) do
    if MapSet.new(Map.keys(map)) == MapSet.new(keys),
      do: :ok,
      else: {:error, :unexpected_callback_result_field}
  end

  defp stringify(map) when is_map(map),
    do: Map.new(map, fn {key, item} -> {to_string(key), item} end)

  defp stringify(_map), do: %{}

  defp required({:ok, nil}), do: {:error, :callback_command_resource_not_found}
  defp required({:ok, value}), do: {:ok, value}
  defp required({:error, reason}), do: {:error, reason}

  defp uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, normalized} -> {:ok, normalized}
      :error -> {:error, :invalid_callback_command_id}
    end
  end

  defp uuid(_value), do: {:error, :invalid_callback_command_id}

  defp now(opts),
    do: opts |> Keyword.get(:now, DateTime.utc_now()) |> DateTime.truncate(:microsecond)

  defp error_code(reason), do: SafeFailureEvidence.code(reason)

  defp same_id?(left, right), do: to_string(left) == to_string(right)
  defp nonempty?(value), do: is_binary(value) and String.trim(value) != ""
  defp safe_id(value) when is_binary(value), do: String.slice(value, 0, 64)
  defp safe_id(_value), do: nil
  defp value(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp value(_map, _key), do: nil
end
