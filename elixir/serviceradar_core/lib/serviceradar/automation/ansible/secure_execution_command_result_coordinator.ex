defmodule ServiceRadar.Automation.Ansible.SecureExecutionCommandResultCoordinator do
  @moduledoc """
  Replay-safe result coordinator for hardened non-callback AWX executions.

  Gateway results are authenticated wake-up signals only. Correlation and all
  selectors come from the persisted `AgentCommand`, its versioned context, and
  the immutable secure-execution attempt. Callback attempts are ignored.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Automation.Ansible.AutomationExecution
  alias ServiceRadar.Automation.Ansible.AutomationExecutionTarget
  alias ServiceRadar.Automation.Ansible.AutomationOperation

  alias ServiceRadar.Automation.Ansible.AutomationSecureExecutionCommandAttempt,
    as: Attempt

  alias ServiceRadar.Automation.Ansible.Controller
  alias ServiceRadar.Automation.Ansible.ExecutionLifecycle
  alias ServiceRadar.Automation.Ansible.SafeFailureEvidence
  alias ServiceRadar.Automation.Ansible.SecureExecutionCommandContract, as: Contract
  alias ServiceRadar.Automation.Ansible.SecureExecutionCommandDispatcher
  alias ServiceRadar.Automation.Ansible.SecureExecutionLifecycle
  alias ServiceRadar.Automation.CallbackGrants.CanonicalJSON
  alias ServiceRadar.Edge.AgentCommand
  alias ServiceRadar.Repo

  require Logger

  @actor SystemActor.system(:secure_execution_command_result_coordinator)
  @processing_lease_seconds 30
  @launch_reconcile_seconds 30
  @default_execution_seconds 86_400
  @max_execution_seconds 604_800
  @command_types [
    "awx.launch_job",
    "awx.fetch_job",
    "awx.list_recent_jobs",
    "awx.fetch_job_host_summaries",
    "awx.cancel_job"
  ]
  @terminal_command_states [:completed, :failed, :expired, :canceled, :offline]

  @spec handle_command_result(map(), keyword()) :: {:ok, atom()} | {:error, term()} | :ignored
  def handle_command_result(data, opts \\ [])

  def handle_command_result(data, opts) when is_map(data) and is_list(opts) do
    command_id = value(data, :command_id)
    command_type = value(data, :command_type)
    authenticated_agent_id = value(data, :agent_id)

    if command_type in @command_types do
      with {:ok, command_id} <- uuid(command_id),
           true <- nonempty?(authenticated_agent_id) || {:error, :authenticated_agent_required} do
        case process_persisted(command_id, authenticated_agent_id, command_type, opts) do
          {:error, :secure_execution_attempt_not_found} -> :ignored
          result -> result
        end
      else
        false -> {:error, :authenticated_agent_required}
        {:error, _reason} = error -> error
      end
    else
      :ignored
    end
  rescue
    exception ->
      Logger.error("secure execution result coordination crashed",
        command_id: safe_id(value(data, :command_id)),
        exception: exception.__struct__
      )

      {:error, :secure_execution_result_coordination_unavailable}
  catch
    kind, _reason ->
      Logger.error("secure execution result coordination threw",
        command_id: safe_id(value(data, :command_id)),
        failure_kind: kind
      )

      {:error, :secure_execution_result_coordination_unavailable}
  end

  def handle_command_result(_data, _opts), do: {:error, :invalid_secure_execution_result}

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
         :ok <- ensure_non_callback(bundle.operation),
         :ok <- terminal_command(bundle.command) do
      process_terminal_bundle(bundle, now, opts)
    end
  rescue
    exception ->
      Logger.error("persisted secure execution result processing crashed",
        command_id: safe_id(command_id),
        exception: exception.__struct__
      )

      {:error, :secure_execution_result_coordination_unavailable}
  catch
    kind, _reason ->
      Logger.error("persisted secure execution result processing threw",
        command_id: safe_id(command_id),
        failure_kind: kind
      )

      {:error, :secure_execution_result_coordination_unavailable}
  end

  def process_persisted(_command_id, _agent_id, _command_type, _opts),
    do: {:error, :invalid_secure_execution_result}

  @doc "Reconciles an expired transport without retransmitting a launch."
  @spec reconcile_transport_ambiguity(Attempt.t(), keyword()) ::
          {:ok, atom()} | {:error, term()}
  def reconcile_transport_ambiguity(attempt, opts \\ [])

  def reconcile_transport_ambiguity(%Attempt{} = attempt, opts) do
    now = now(opts)

    with {:ok, bundle} <- load_bundle(attempt.command_id, opts),
         true <-
           same_id?(bundle.attempt.id, attempt.id) || {:error, :secure_execution_attempt_changed},
         :ok <- ensure_non_callback(bundle.operation),
         {:ok, claimed, token} <- claim_processing(bundle.attempt, now, opts) do
      bundle
      |> Map.put(:attempt, claimed)
      |> reconcile_claimed_transport(token, nil, now, opts)
    else
      false -> {:error, :secure_execution_attempt_changed}
      {:error, _reason} = error -> error
    end
  end

  def reconcile_transport_ambiguity(_attempt, _opts),
    do: {:error, :invalid_secure_execution_command_attempt}

  @doc "Fails a durable attempt whose bounded deadline elapsed."
  @spec expire_attempt(Attempt.t(), keyword()) :: {:ok, atom()} | {:error, term()}
  def expire_attempt(attempt, opts \\ [])

  def expire_attempt(%Attempt{} = attempt, opts) do
    now = now(opts)

    with true <- not DateTime.before?(now, attempt.deadline_at) || {:error, :deadline_not_elapsed},
         {:ok, bundle} <- load_resources_for_attempt(attempt, opts),
         :ok <- ensure_non_callback(bundle.operation),
         {:ok, claimed, token} <- claim_processing(attempt, now, opts) do
      bundle = Map.put(bundle, :attempt, claimed)

      case attempt.stage do
        stage when stage in [:launch_job, :list_recent_jobs] ->
          dispatch_ambiguous(
            bundle,
            token,
            nil,
            :launch_reconciliation_deadline_elapsed,
            [],
            now,
            opts
          )

        :cancel_job ->
          mark_cancel_failed(bundle, token, nil, :cancel_deadline_elapsed, now, opts)

        _stage ->
          cancel_job_ids =
            if is_integer(attempt.expected_job_id), do: [attempt.expected_job_id], else: []

          fail_known_execution(
            bundle,
            token,
            nil,
            :secure_execution_deadline_elapsed,
            now,
            Keyword.put(opts, :cancel_job_ids, cancel_job_ids)
          )
      end
    else
      false -> {:error, :deadline_not_elapsed}
      {:error, _reason} = error -> error
    end
  end

  def expire_attempt(_attempt, _opts), do: {:error, :invalid_secure_execution_command_attempt}

  defp load_bundle(command_id, opts) do
    loader = Keyword.get(opts, :bundle_loader, &load_persisted_bundle/1)
    loader.(command_id)
  end

  defp load_persisted_bundle(command_id) do
    with {:ok, %AgentCommand{} = command} <-
           required(AgentCommand.get_by_id(command_id, actor: @actor), :agent_command_not_found),
         {:ok, %Attempt{} = attempt} <-
           required(
             Attempt.get_by_command_id(command_id, actor: @actor),
             :secure_execution_attempt_not_found
           ),
         {:ok, %AutomationOperation{} = operation} <-
           required(
             AutomationOperation.get_by_id(attempt.operation_id, actor: @actor),
             :secure_execution_operation_not_found
           ),
         {:ok, %AutomationExecution{} = execution} <-
           required(
             AutomationExecution.get_by_id(attempt.execution_id, actor: @actor),
             :secure_execution_not_found
           ),
         {:ok, targets} <-
           AutomationExecutionTarget.list_for_execution(execution.id, actor: @actor),
         true <- targets != [] || {:error, :secure_execution_targets_missing},
         {:ok, %Controller{} = controller} <-
           required(
             Controller.get_by_id(attempt.controller_id, actor: @actor),
             :secure_execution_controller_not_found
           ) do
      {:ok,
       %{
         command: command,
         attempt: attempt,
         operation: operation,
         execution: execution,
         targets: targets,
         controller: controller
       }}
    else
      false -> {:error, :secure_execution_targets_missing}
      {:error, _reason} = error -> error
    end
  end

  defp load_resources_for_attempt(attempt, opts) do
    loader = Keyword.get(opts, :attempt_bundle_loader, &load_persisted_resources_for_attempt/1)
    loader.(attempt)
  end

  defp load_persisted_resources_for_attempt(attempt) do
    with {:ok, %AutomationOperation{} = operation} <-
           required(
             AutomationOperation.get_by_id(attempt.operation_id, actor: @actor),
             :secure_execution_operation_not_found
           ),
         {:ok, %AutomationExecution{} = execution} <-
           required(
             AutomationExecution.get_by_id(attempt.execution_id, actor: @actor),
             :secure_execution_not_found
           ),
         {:ok, targets} <-
           AutomationExecutionTarget.list_for_execution(execution.id, actor: @actor),
         true <- targets != [] || {:error, :secure_execution_targets_missing},
         {:ok, %Controller{} = controller} <-
           required(
             Controller.get_by_id(attempt.controller_id, actor: @actor),
             :secure_execution_controller_not_found
           ) do
      {:ok,
       %{
         attempt: attempt,
         operation: operation,
         execution: execution,
         targets: targets,
         controller: controller
       }}
    else
      false -> {:error, :secure_execution_targets_missing}
      {:error, _reason} = error -> error
    end
  end

  defp exact_authenticated_provenance(bundle, authenticated_agent_id, reported_type) do
    cond do
      bundle.command.agent_id != authenticated_agent_id ->
        {:error, :secure_execution_authenticated_agent_mismatch}

      bundle.attempt.dispatch_agent_id != authenticated_agent_id ->
        {:error, :secure_execution_attempt_agent_mismatch}

      bundle.command.command_type != reported_type ->
        {:error, :secure_execution_reported_type_mismatch}

      true ->
        :ok
    end
  end

  defp ensure_non_callback(%{callback_actions: []}), do: :ok
  defp ensure_non_callback(_operation), do: {:error, :callback_execution_isolated}

  defp terminal_command(%AgentCommand{status: status}) when status in @terminal_command_states,
    do: :ok

  defp terminal_command(_command), do: {:error, :secure_execution_command_not_terminal}

  defp process_terminal_bundle(bundle, now, opts) do
    case attempt_state(bundle.attempt) do
      :terminal ->
        with {:ok, request} <- rebuild_request(bundle),
             :ok <- exact_persisted_contract(bundle, request),
             :ok <- exact_replay_result(bundle) do
          {:ok, :already_processed}
        end

      :active ->
        with {:ok, claimed, token} <- claim_processing(bundle.attempt, now, opts) do
          bundle
          |> Map.put(:attempt, claimed)
          |> process_claimed_terminal(token, now, opts)
        end
    end
  end

  defp process_claimed_terminal(bundle, token, now, opts) do
    with {:ok, digest} <- result_digest(bundle.command),
         {:ok, request} <- rebuild_request(bundle),
         :ok <- exact_persisted_contract(bundle, request) do
      if successful_command?(bundle.command) do
        process_success(bundle, request, token, digest, now, opts)
      else
        process_command_failure(bundle, request, token, digest, now, opts)
      end
    else
      {:error, reason} -> fail_known_execution(bundle, token, nil, reason, now, opts)
    end
  end

  defp reconcile_claimed_transport(
         %{attempt: %Attempt{stage: :launch_job}} = bundle,
         token,
         digest,
         now,
         opts
       ) do
    # The durable attempt is inserted before dispatch. Use that lower bound,
    # widened for bounded controller clock skew, rather than dispatched_at,
    # which is recorded after the command bus call and could exclude a job AWX
    # accepted just before the caller observed dispatch completion.
    reconcile_after =
      case bundle.attempt.inserted_at do
        %DateTime{} = inserted_at -> DateTime.add(inserted_at, -300, :second)
        _missing -> bundle.attempt.dispatched_at || now
      end

    deadline_at = DateTime.add(now, @launch_reconcile_seconds, :second)

    with {:ok, request} <- Contract.recent_jobs_request(bundle.execution, reconcile_after),
         {:ok, attrs} <-
           next_attempt_attrs(bundle, request, now,
             stage: :list_recent_jobs,
             purpose: :launch_reconciliation,
             command_type: "awx.list_recent_jobs",
             reconcile_after: reconcile_after,
             deadline_at: deadline_at
           ),
         {:ok, next} <-
           finish_with_next(
             bundle.attempt,
             token,
             digest,
             :ambiguous,
             :launch_transport_ambiguous,
             attrs,
             now,
             opts
           ),
         :ok <- dispatch_after_commit(next, opts) do
      {:ok, :launch_transport_ambiguous}
    end
  end

  defp reconcile_claimed_transport(bundle, token, digest, now, opts) do
    case read_only_retry_attrs(bundle, now, opts) do
      {:ok, attrs} ->
        with {:ok, next} <-
               finish_with_next(
                 bundle.attempt,
                 token,
                 digest,
                 :ambiguous,
                 :read_only_transport_retry,
                 attrs,
                 now,
                 opts
               ),
             :ok <- dispatch_after_commit(next, opts) do
          {:ok, :read_only_transport_retry}
        end

      {:error, reason} ->
        fail_known_execution(bundle, token, nil, reason, now, opts)
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
         {:ok, request} <- Contract.fetch_job_request(job_id),
         {:ok, attrs} <-
           next_attempt_attrs(bundle, request, now,
             stage: :fetch_job,
             purpose: :accepted_job_proof,
             command_type: "awx.fetch_job",
             expected_job_id: job_id,
             deadline_at: execution_deadline(bundle, now)
           ),
         {:ok, next} <-
           complete_with_next(
             bundle.attempt,
             token,
             digest,
             :launch_acknowledged,
             attrs,
             now,
             opts
           ) do
      dispatch_after_commit(next, opts)
      {:ok, :launch_acknowledged}
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
         {:ok, request} <-
           Contract.host_summaries_request(bundle.attempt.expected_job_id, length(bundle.targets)),
         {:ok, attrs} <-
           next_attempt_attrs(bundle, request, now,
             stage: :fetch_host_summaries,
             purpose: :host_scope_proof,
             command_type: "awx.fetch_job_host_summaries",
             expected_job_id: bundle.attempt.expected_job_id,
             deadline_at: execution_deadline(bundle, now)
           ),
         {:ok, execution} <-
           bind_accepted_job(bundle, job, opts),
         bundle = %{bundle | execution: execution},
         {:ok, next} <-
           complete_with_next(
             bundle.attempt,
             token,
             digest,
             :accepted_job_verified,
             attrs,
             now,
             opts
           ) do
      dispatch_after_commit(next, opts)
      {:ok, :accepted_job_verified}
    else
      {:error, reason} ->
        fail_known_execution(
          bundle,
          token,
          digest,
          reason,
          now,
          Keyword.put(opts, :cancel_job_ids, [bundle.attempt.expected_job_id])
        )
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
    with {:ok, job} <- exact_fetch_job_result(bundle),
         :ok <-
           SecureExecutionLifecycle.validate_bound_job(
             bundle.execution,
             bundle.controller.id,
             job
           ),
         {:ok, request} <-
           Contract.host_summaries_request(bundle.attempt.expected_job_id, length(bundle.targets)),
         {:ok, attrs} <-
           next_attempt_attrs(bundle, request, now,
             stage: :fetch_host_summaries,
             purpose: :host_scope_proof,
             command_type: "awx.fetch_job_host_summaries",
             expected_job_id: bundle.attempt.expected_job_id,
             deadline_at: execution_deadline(bundle, now)
           ),
         {:ok, next} <-
           complete_with_next(
             bundle.attempt,
             token,
             digest,
             :scope_poll_complete,
             attrs,
             now,
             opts
           ) do
      dispatch_after_commit(next, opts)
      {:ok, :scope_poll_complete}
    else
      {:error, reason} ->
        fail_known_execution(
          bundle,
          token,
          digest,
          reason,
          now,
          Keyword.put(opts, :cancel_job_ids, [bundle.attempt.expected_job_id])
        )
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
    case exact_summary_result(bundle) do
      {:ok, summaries} ->
        case ExecutionLifecycle.classify_host_scope(
               bundle.execution,
               bundle.targets,
               bundle.controller.id,
               bundle.attempt.expected_job_id,
               summaries
             ) do
          {:ok, :exact} ->
            activate_running(bundle, summaries, token, digest, now, opts)

          {:retry, :host_scope_incomplete} ->
            schedule_scope_poll(bundle, token, digest, now, opts)

          {:error, reason} ->
            fail_known_execution(
              bundle,
              token,
              digest,
              reason,
              now,
              Keyword.put(opts, :cancel_job_ids, [bundle.attempt.expected_job_id])
            )
        end

      {:error, reason} ->
        fail_known_execution(
          bundle,
          token,
          digest,
          reason,
          now,
          Keyword.put(opts, :cancel_job_ids, [bundle.attempt.expected_job_id])
        )
    end
  end

  defp process_success(
         %{attempt: %Attempt{stage: :fetch_job, purpose: :terminal_poll}} = bundle,
         _request,
         token,
         digest,
         now,
         opts
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
        :active -> schedule_terminal_poll(bundle, token, digest, now, opts)
        _terminal -> schedule_terminal_confirmation(bundle, job, token, digest, now, opts)
      end
    else
      {:error, reason} ->
        fail_known_execution(
          bundle,
          token,
          digest,
          reason,
          now,
          Keyword.put(opts, :cancel_job_ids, [bundle.attempt.expected_job_id])
        )
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
           Contract.terminal_job_snapshot?(bundle.attempt.terminal_job_snapshot) ||
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
          schedule_terminal_summary_poll(bundle, token, digest, now, opts)

        {:error, reason} ->
          fail_known_execution(bundle, token, digest, reason, now, opts)
      end
    else
      false -> {:error, :terminal_job_evidence_missing}
      {:error, reason} -> fail_known_execution(bundle, token, digest, reason, now, opts)
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
         {:ok, candidates} <- reconciled_candidates(bundle, result.jobs) do
      cond do
        result.truncated? ->
          dispatch_ambiguous(bundle, token, digest, :recent_jobs_truncated, candidates, now, opts)

        length(candidates) == 1 ->
          reconcile_unique_candidate(bundle, hd(candidates), token, digest, now, opts)

        candidates == [] ->
          schedule_recent_jobs_poll(bundle, request, token, digest, now, opts)

        true ->
          dispatch_ambiguous(
            bundle,
            token,
            digest,
            :multiple_launch_candidates,
            candidates,
            now,
            opts
          )
      end
    else
      {:error, reason} -> dispatch_ambiguous(bundle, token, digest, reason, [], now, opts)
    end
  end

  defp process_success(
         %{attempt: %Attempt{stage: :cancel_job}} = bundle,
         _request,
         token,
         digest,
         now,
         opts
       ) do
    case exact_cancel_result(bundle) do
      :ok ->
        case bundle.attempt.candidate_job_ids do
          [next_job_id | remaining] ->
            with {:ok, request} <- Contract.cancel_job_request(next_job_id),
                 {:ok, attrs} <-
                   next_attempt_attrs(bundle, request, now,
                     stage: :cancel_job,
                     purpose: :terminal_cleanup,
                     command_type: "awx.cancel_job",
                     expected_job_id: next_job_id,
                     candidate_job_ids: remaining,
                     deadline_at: DateTime.add(now, 60, :second)
                   ),
                 {:ok, next} <-
                   complete_with_next(
                     bundle.attempt,
                     token,
                     digest,
                     :candidate_canceled,
                     attrs,
                     now,
                     opts
                   ) do
              dispatch_after_commit(next, opts)
              {:ok, :candidate_canceled}
            end

          [] ->
            with {:ok, _attempt} <-
                   attempt_store(opts).mark_succeeded(
                     bundle.attempt,
                     %{
                       lease_token: token,
                       processed_at: now,
                       outcome_code: "cleanup_complete",
                       result_digest: digest
                     },
                     actor: @actor
                   ) do
              {:ok, :cleanup_complete}
            end
        end

      {:error, reason} ->
        mark_cancel_failed(bundle, token, digest, reason, now, opts)
    end
  end

  defp process_success(bundle, _request, token, digest, now, opts),
    do:
      fail_known_execution(
        bundle,
        token,
        digest,
        :secure_execution_stage_not_processable,
        now,
        opts
      )

  defp process_command_failure(
         %{attempt: %Attempt{stage: :launch_job}} = bundle,
         _request,
         token,
         digest,
         now,
         opts
       ),
       do: reconcile_claimed_transport(bundle, token, digest, now, opts)

  defp process_command_failure(
         %{attempt: %Attempt{stage: :cancel_job}} = bundle,
         _request,
         token,
         digest,
         now,
         opts
       ),
       do: mark_cancel_failed(bundle, token, digest, :cancel_command_failed, now, opts)

  defp process_command_failure(bundle, _request, token, digest, now, opts) do
    case read_only_retry_attrs(bundle, now, opts) do
      {:ok, attrs} ->
        with {:ok, next} <-
               finish_with_next(
                 bundle.attempt,
                 token,
                 digest,
                 :ambiguous,
                 :read_only_command_retry,
                 attrs,
                 now,
                 opts
               ) do
          dispatch_after_commit(next, opts)
          {:ok, :read_only_command_retry}
        end

      {:error, reason} ->
        fail_known_execution(bundle, token, digest, reason, now, opts)
    end
  end

  defp activate_running(bundle, summaries, token, digest, now, opts) do
    poll_attempt =
      next_attempt_number(
        bundle.attempt,
        Keyword.merge(opts, stage: :fetch_job, purpose: :terminal_poll)
      )

    with {:ok, request} <- Contract.fetch_job_request(bundle.attempt.expected_job_id),
         next_at = DateTime.add(now, poll_delay_seconds(poll_attempt), :second),
         {:ok, attrs} <-
           next_attempt_attrs(bundle, request, now,
             stage: :fetch_job,
             purpose: :terminal_poll,
             command_type: "awx.fetch_job",
             attempt: poll_attempt,
             expected_job_id: bundle.attempt.expected_job_id,
             next_attempt_at: next_at,
             deadline_at: execution_deadline(bundle, now)
           ),
         {:ok, next} <-
           transaction(opts, fn ->
             with {:ok, scope} <-
                    ExecutionLifecycle.verify_host_scope(
                      bundle.execution,
                      bundle.targets,
                      bundle.controller.id,
                      bundle.attempt.expected_job_id,
                      summaries,
                      lifecycle_opts(opts, :execution_lifecycle_actions,
                        mutating?: bundle.operation.mutating
                      )
                    ),
                  {:ok, running} <-
                    SecureExecutionLifecycle.mark_running(
                      bundle.operation,
                      scope.execution,
                      lifecycle_opts(opts, :secure_lifecycle_actions)
                    ),
                  {:ok, _completed} <-
                    attempt_store(opts).mark_succeeded(
                      bundle.attempt,
                      %{
                        lease_token: token,
                        processed_at: now,
                        outcome_code: "scope_verified_running",
                        result_digest: digest
                      },
                      actor: @actor
                    ),
                  {:ok, next} <- attempt_store(opts).create_planned(attrs, actor: @actor) do
               _ = running
               next
             else
               {:error, reason} -> rollback(opts, reason)
             end
           end) do
      dispatch_after_commit(next, opts)
      {:ok, :scope_verified_running}
    else
      {:error, reason} ->
        fail_known_execution(
          bundle,
          token,
          digest,
          reason,
          now,
          Keyword.put(opts, :cancel_job_ids, [bundle.attempt.expected_job_id])
        )
    end
  end

  defp schedule_scope_poll(bundle, token, digest, now, opts) do
    poll_attempt =
      next_attempt_number(
        bundle.attempt,
        Keyword.merge(opts, stage: :fetch_job, purpose: :scope_poll)
      )

    next_at = DateTime.add(now, poll_delay_seconds(poll_attempt), :second)

    with :ok <- before_deadline(bundle.attempt, next_at),
         {:ok, request} <- Contract.fetch_job_request(bundle.attempt.expected_job_id),
         {:ok, attrs} <-
           next_attempt_attrs(bundle, request, now,
             stage: :fetch_job,
             purpose: :scope_poll,
             command_type: "awx.fetch_job",
             attempt: poll_attempt,
             expected_job_id: bundle.attempt.expected_job_id,
             next_attempt_at: next_at,
             deadline_at: execution_deadline(bundle, now)
           ),
         {:ok, next} <-
           complete_with_next(
             bundle.attempt,
             token,
             digest,
             :host_scope_incomplete,
             attrs,
             now,
             opts
           ) do
      dispatch_after_commit(next, opts)
      {:ok, :host_scope_incomplete}
    end
  end

  defp schedule_terminal_poll(bundle, token, digest, now, opts) do
    poll_attempt =
      next_attempt_number(
        bundle.attempt,
        Keyword.merge(opts, stage: :fetch_job, purpose: :terminal_poll)
      )

    next_at = DateTime.add(now, poll_delay_seconds(poll_attempt), :second)

    with {:ok, request} <- Contract.fetch_job_request(bundle.attempt.expected_job_id),
         {:ok, attrs} <-
           next_attempt_attrs(bundle, request, now,
             stage: :fetch_job,
             purpose: :terminal_poll,
             command_type: "awx.fetch_job",
             attempt: poll_attempt,
             expected_job_id: bundle.attempt.expected_job_id,
             next_attempt_at: next_at,
             deadline_at: execution_deadline(bundle, now)
           ),
         {:ok, next} <-
           complete_with_next(bundle.attempt, token, digest, :job_still_active, attrs, now, opts) do
      dispatch_after_commit(next, opts)
      {:ok, :job_still_active}
    end
  end

  defp schedule_terminal_confirmation(bundle, job, token, digest, now, opts) do
    with {:ok, request} <-
           Contract.host_summaries_request(bundle.attempt.expected_job_id, length(bundle.targets)),
         {:ok, attrs} <-
           next_attempt_attrs(bundle, request, now,
             stage: :fetch_host_summaries,
             purpose: :terminal_confirmation,
             command_type: "awx.fetch_job_host_summaries",
             expected_job_id: bundle.attempt.expected_job_id,
             terminal_job_snapshot: job,
             deadline_at: execution_deadline(bundle, now)
           ),
         {:ok, next} <-
           complete_with_next(
             bundle.attempt,
             token,
             digest,
             :terminal_job_observed,
             attrs,
             now,
             opts
           ) do
      dispatch_after_commit(next, opts)
      {:ok, :terminal_job_observed}
    end
  end

  defp schedule_terminal_summary_poll(bundle, token, digest, now, opts) do
    case read_only_retry_attrs(bundle, now, opts) do
      {:ok, attrs} ->
        with {:ok, next} <-
               complete_with_next(
                 bundle.attempt,
                 token,
                 digest,
                 :terminal_host_summaries_incomplete,
                 attrs,
                 now,
                 opts
               ) do
          dispatch_after_commit(next, opts)
          {:ok, :terminal_host_summaries_incomplete}
        end

      {:error, reason} ->
        fail_known_execution(bundle, token, digest, reason, now, opts)
    end
  end

  defp persist_terminal_result(bundle, summaries, token, digest, now, opts) do
    case transaction(opts, fn ->
           with {:ok, lifecycle} <-
                  SecureExecutionLifecycle.complete_terminal(
                    bundle.operation,
                    bundle.execution,
                    bundle.targets,
                    bundle.controller.id,
                    bundle.attempt.terminal_job_snapshot,
                    summaries,
                    lifecycle_opts(opts, :secure_lifecycle_actions)
                  ),
                {:ok, _attempt} <-
                  attempt_store(opts).mark_succeeded(
                    bundle.attempt,
                    %{
                      lease_token: token,
                      processed_at: now,
                      outcome_code: "terminal_state_persisted",
                      result_digest: digest
                    },
                    actor: @actor
                  ) do
             lifecycle
           else
             {:error, reason} -> rollback(opts, reason)
           end
         end) do
      {:ok, _outcome} ->
        {:ok, :terminal_state_persisted}

      {:error, reason} ->
        fail_known_execution(bundle, token, digest, reason, now, opts)
    end
  end

  defp schedule_recent_jobs_poll(bundle, request, token, digest, now, opts) do
    next_at = DateTime.add(now, 1, :second)

    if DateTime.before?(next_at, bundle.attempt.deadline_at) do
      with {:ok, attrs} <-
             next_attempt_attrs(bundle, request, now,
               stage: :list_recent_jobs,
               purpose: :launch_reconciliation,
               command_type: "awx.list_recent_jobs",
               reconcile_after: bundle.attempt.reconcile_after,
               next_attempt_at: next_at,
               deadline_at: bundle.attempt.deadline_at
             ),
           {:ok, next} <-
             complete_with_next(
               bundle.attempt,
               token,
               digest,
               :launch_candidate_not_visible,
               attrs,
               now,
               opts
             ) do
        dispatch_after_commit(next, opts)
        {:ok, :launch_candidate_not_visible}
      end
    else
      dispatch_ambiguous(bundle, token, digest, :launch_candidate_not_found, [], now, opts)
    end
  end

  defp reconcile_unique_candidate(bundle, candidate, token, digest, now, opts) do
    with {:ok, request} <- Contract.fetch_job_request(candidate.job_id),
         {:ok, attrs} <-
           next_attempt_attrs(bundle, request, now,
             stage: :fetch_job,
             purpose: :accepted_job_proof,
             command_type: "awx.fetch_job",
             expected_job_id: candidate.job_id,
             deadline_at: execution_deadline(bundle, now)
           ),
         {:ok, next} <-
           complete_with_next(bundle.attempt, token, digest, :launch_reconciled, attrs, now, opts) do
      dispatch_after_commit(next, opts)
      {:ok, :launch_reconciled}
    end
  end

  defp dispatch_ambiguous(bundle, token, digest, reason, candidates, now, opts) do
    job_ids = candidates |> Enum.map(& &1.job_id) |> Enum.uniq() |> Enum.sort()

    fail_known_execution(
      bundle,
      token,
      digest,
      reason,
      now,
      opts
      |> Keyword.put(:failure_state, :dispatch_ambiguous)
      |> Keyword.put(:attempt_terminal_state, :ambiguous)
      |> Keyword.put(:cancel_job_ids, job_ids)
    )
  end

  defp fail_known_execution(bundle, token, digest, reason, now, opts) do
    state = Keyword.get(opts, :failure_state, :failed)
    attempt_state = Keyword.get(opts, :attempt_terminal_state, :failed)
    job_ids = opts |> Keyword.get(:cancel_job_ids, []) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    with {:ok, next_attrs} <- optional_cancel_attrs(bundle, job_ids, now),
         {:ok, next} <-
           transaction(opts, fn ->
             with {:ok, _lifecycle} <-
                    SecureExecutionLifecycle.fail_closed(
                      bundle.operation,
                      bundle.execution,
                      bundle.targets,
                      state,
                      reason,
                      lifecycle_opts(opts, :secure_lifecycle_actions,
                        cancel_required: job_ids != []
                      )
                    ),
                  {:ok, _attempt} <-
                    finish_attempt(
                      bundle.attempt,
                      token,
                      digest,
                      attempt_state,
                      reason,
                      now,
                      opts
                    ),
                  {:ok, next} <- create_optional_attempt(next_attrs, opts) do
               next
             else
               {:error, failure} -> rollback(opts, failure)
             end
           end) do
      dispatch_after_commit(next, opts)
      {:ok, if(state == :dispatch_ambiguous, do: :dispatch_ambiguous, else: :failed_closed)}
    end
  end

  defp mark_cancel_failed(bundle, token, digest, reason, now, opts) do
    fail_known_execution(
      bundle,
      token,
      digest,
      reason,
      now,
      opts
      |> Keyword.put(:failure_state, :cancel_failed)
      |> Keyword.put(:attempt_terminal_state, :failed)
      |> Keyword.put(:cancel_job_ids, [])
    )
  end

  defp optional_cancel_attrs(_bundle, [], _now), do: {:ok, nil}

  defp optional_cancel_attrs(bundle, [job_id | remaining], now) do
    with {:ok, request} <- Contract.cancel_job_request(job_id) do
      next_attempt_attrs(bundle, request, now,
        stage: :cancel_job,
        purpose: :terminal_cleanup,
        command_type: "awx.cancel_job",
        expected_job_id: job_id,
        candidate_job_ids: remaining,
        deadline_at: DateTime.add(now, 60, :second)
      )
    end
  end

  defp create_optional_attempt(nil, _opts), do: {:ok, nil}

  defp create_optional_attempt(attrs, opts),
    do: attempt_store(opts).create_planned(attrs, actor: @actor)

  defp bind_accepted_job(bundle, job, opts) do
    ExecutionLifecycle.bind_accepted_job(
      bundle.execution,
      bundle.controller.id,
      job,
      lifecycle_opts(opts, :execution_lifecycle_actions,
        targets: bundle.targets,
        mutating?: bundle.operation.mutating
      )
    )
  end

  defp rebuild_request(%{attempt: %Attempt{stage: :launch_job}} = bundle),
    do: Contract.launch_request(bundle.operation, bundle.execution)

  defp rebuild_request(%{attempt: %Attempt{stage: :fetch_job}} = bundle),
    do: Contract.fetch_job_request(bundle.attempt.expected_job_id)

  defp rebuild_request(%{attempt: %Attempt{stage: :fetch_host_summaries}} = bundle),
    do: Contract.host_summaries_request(bundle.attempt.expected_job_id, length(bundle.targets))

  defp rebuild_request(%{attempt: %Attempt{stage: :list_recent_jobs}} = bundle),
    do: Contract.recent_jobs_request(bundle.execution, bundle.attempt.reconcile_after)

  defp rebuild_request(%{attempt: %Attempt{stage: :cancel_job}} = bundle),
    do: Contract.cancel_job_request(bundle.attempt.expected_job_id)

  defp rebuild_request(_bundle), do: {:error, :secure_execution_stage_not_processable}

  defp exact_persisted_contract(bundle, request) do
    checks = [
      same_id?(bundle.command.id, bundle.attempt.command_id),
      bundle.command.command_type == bundle.attempt.command_type,
      bundle.command.agent_id == bundle.attempt.dispatch_agent_id,
      same_id?(bundle.execution.id, bundle.attempt.execution_id),
      same_id?(bundle.operation.id, bundle.attempt.operation_id),
      same_id?(bundle.controller.id, bundle.attempt.controller_id),
      bundle.execution.operation_id == bundle.operation.id,
      bundle.execution.controller_id == bundle.controller.id,
      Contract.request_matches?(bundle.attempt, request),
      Contract.context_matches?(bundle.attempt, bundle.execution, bundle.command.context || %{}),
      Contract.persisted_payload_matches?(
        bundle.attempt,
        bundle.execution,
        bundle.controller,
        request,
        bundle.command.payload || %{}
      )
    ]

    if Enum.all?(checks), do: :ok, else: {:error, :secure_execution_command_correlation_mismatch}
  end

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
      _ -> {:error, :secure_execution_launch_result_mismatch}
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
      _ -> {:error, :secure_execution_fetch_job_result_mismatch}
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
      _ -> {:error, :secure_execution_host_summary_result_mismatch}
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
         true <- payload["template_id"] == request.template_id,
         true <- payload["inventory_id"] == request.inventory_id,
         true <- payload["created_by_id"] == request.created_by_id,
         true <- payload["created_after"] == request.created_after,
         true <- payload["page_size"] == request.page_size,
         count when is_integer(count) and count >= 0 <- payload["count"],
         truncated when is_boolean(truncated) <- payload["truncated"],
         jobs when is_list(jobs) <- payload["jobs"],
         true <- length(jobs) <= request.page_size,
         true <- (truncated and count >= length(jobs)) or count == length(jobs) do
      {:ok, %{jobs: jobs, truncated?: truncated}}
    else
      _ -> {:error, :secure_execution_recent_jobs_result_mismatch}
    end
  end

  defp exact_cancel_result(bundle) do
    payload = stringify(bundle.command.result_payload)

    with :ok <- exact_keys(payload, ~w(verb ok job_id status)),
         true <- payload["verb"] == bundle.attempt.command_type,
         true <- payload["ok"] == true,
         true <- payload["job_id"] == bundle.attempt.expected_job_id,
         status when is_integer(status) and status in 200..299 <- payload["status"] do
      :ok
    else
      _ -> {:error, :secure_execution_cancel_result_mismatch}
    end
  end

  defp reconciled_candidates(bundle, jobs) do
    candidates =
      jobs
      |> Enum.reduce([], fn job, acc ->
        case ExecutionLifecycle.accepted_job_snapshot(bundle.execution, bundle.controller.id, job) do
          {:ok, snapshot} -> [%{job_id: snapshot["awx_job_id"], job: job} | acc]
          {:error, _reason} -> acc
        end
      end)
      |> Enum.uniq_by(& &1.job_id)
      |> Enum.sort_by(& &1.job_id)

    {:ok, candidates}
  end

  defp read_only_retry_attrs(bundle, now, opts) do
    retry_attempt =
      next_attempt_number(
        bundle.attempt,
        Keyword.merge(opts,
          stage: bundle.attempt.stage,
          purpose: bundle.attempt.purpose
        )
      )

    next_at = DateTime.add(now, poll_delay_seconds(retry_attempt), :second)

    with :ok <- before_deadline(bundle.attempt, next_at),
         {:ok, request} <- rebuild_request(bundle) do
      next_attempt_attrs(bundle, request, now,
        stage: bundle.attempt.stage,
        purpose: bundle.attempt.purpose,
        command_type: bundle.attempt.command_type,
        attempt: retry_attempt,
        expected_job_id: bundle.attempt.expected_job_id,
        reconcile_after: bundle.attempt.reconcile_after,
        terminal_job_snapshot: bundle.attempt.terminal_job_snapshot,
        candidate_job_ids: bundle.attempt.candidate_job_ids,
        next_attempt_at: next_at,
        deadline_at: bundle.attempt.deadline_at
      )
    end
  end

  defp next_attempt_attrs(bundle, request, _now, opts) do
    Contract.build_attempt(
      %{
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
      attempt:
        Keyword.get_lazy(opts, :attempt, fn -> next_attempt_number(bundle.attempt, opts) end),
      expected_job_id: Keyword.get(opts, :expected_job_id),
      reconcile_after: Keyword.get(opts, :reconcile_after),
      terminal_job_snapshot: Keyword.get(opts, :terminal_job_snapshot),
      candidate_job_ids: Keyword.get(opts, :candidate_job_ids, []),
      deadline_at: Keyword.fetch!(opts, :deadline_at),
      next_attempt_at: Keyword.get(opts, :next_attempt_at)
    )
  end

  defp next_attempt_number(attempt, opts) do
    stage = Keyword.fetch!(opts, :stage)
    purpose = Keyword.fetch!(opts, :purpose)

    case attempt_store(opts).list_for_execution(attempt.execution_id, actor: @actor) do
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

  defp complete_with_next(attempt, token, digest, outcome, attrs, now, opts) do
    transaction(opts, fn ->
      with {:ok, _completed} <-
             attempt_store(opts).mark_succeeded(
               attempt,
               %{
                 lease_token: token,
                 processed_at: now,
                 outcome_code: Atom.to_string(outcome),
                 result_digest: digest
               },
               actor: @actor
             ),
           {:ok, next} <- attempt_store(opts).create_planned(attrs, actor: @actor) do
        next
      else
        {:error, reason} -> rollback(opts, reason)
      end
    end)
  end

  defp finish_with_next(attempt, token, digest, terminal_state, outcome, attrs, now, opts) do
    transaction(opts, fn ->
      with {:ok, _finished} <-
             finish_attempt(attempt, token, digest, terminal_state, outcome, now, opts),
           {:ok, next} <- attempt_store(opts).create_planned(attrs, actor: @actor) do
        next
      else
        {:error, reason} -> rollback(opts, reason)
      end
    end)
  end

  defp finish_attempt(attempt, token, digest, state, outcome, now, opts) do
    action =
      case state do
        :succeeded -> :mark_succeeded
        :failed -> :mark_failed
        :ambiguous -> :mark_ambiguous
      end

    attrs = %{
      lease_token: token,
      processed_at: now,
      outcome_code: error_code(outcome),
      result_digest: digest
    }

    attrs =
      if state == :succeeded,
        do: attrs,
        else: Map.put(attrs, :last_error_code, error_code(outcome))

    apply(attempt_store(opts), action, [attempt, attrs, [actor: @actor]])
  end

  defp dispatch_after_commit(nil, _opts), do: :ok

  defp dispatch_after_commit(%Attempt{} = attempt, opts) do
    dispatcher = Keyword.get(opts, :dispatcher, &SecureExecutionCommandDispatcher.dispatch/1)

    case dispatcher.(attempt) do
      {:ok, _outcome} ->
        :ok

      {:error, reason} ->
        Logger.warning("secure execution follow-up deferred to recovery",
          attempt_id: attempt.id,
          command_id: attempt.command_id,
          reason: error_code(reason)
        )

        :ok
    end
  end

  defp claim_processing(attempt, now, opts) do
    token = Ecto.UUID.generate()
    lease_expires_at = DateTime.add(now, @processing_lease_seconds, :second)
    claimer = Keyword.get(opts, :processing_claimer, &claim_processing_persisted/4)

    case claimer.(attempt, token, lease_expires_at, now) do
      {:ok, claimed} -> {:ok, claimed, token}
      {:error, reason} -> {:error, {:secure_execution_processing_claim_failed, reason}}
    end
  end

  defp claim_processing_persisted(attempt, token, lease_expires_at, now) do
    Attempt.mark_processing(
      attempt,
      %{
        lease_token: token,
        lease_expires_at: lease_expires_at,
        now: now,
        processing_started_at: now
      },
      actor: @actor
    )
  end

  defp execution_deadline(bundle, now) do
    seconds =
      bundle.operation
      |> value(:run_budget)
      |> value(:max_runtime_seconds)
      |> case do
        value when is_integer(value) -> min(max(value, 60), @max_execution_seconds)
        _value -> @default_execution_seconds
      end

    base = value(bundle.execution, :started_at) || now
    DateTime.add(base, seconds, :second)
  end

  @doc false
  def poll_delay_seconds(1), do: 2
  def poll_delay_seconds(2), do: 5
  def poll_delay_seconds(3), do: 10
  def poll_delay_seconds(attempt) when is_integer(attempt) and attempt >= 4, do: 15

  defp before_deadline(attempt, datetime) do
    if DateTime.before?(datetime, attempt.deadline_at),
      do: :ok,
      else: {:error, :secure_execution_command_deadline_elapsed}
  end

  defp successful_command?(%AgentCommand{status: :completed, result_payload: payload})
       when is_map(payload),
       do: value(payload, :ok) == true

  defp successful_command?(_command), do: false

  defp result_digest(%AgentCommand{status: :completed, result_payload: payload})
       when is_map(payload) do
    if value(payload, :ok) == true do
      CanonicalJSON.digest(payload)
    else
      CanonicalJSON.digest(%{"status" => "completed", "result" => "redacted_failure"})
    end
  end

  defp result_digest(%AgentCommand{} = command) do
    CanonicalJSON.digest(%{
      "status" => to_string(command.status),
      "result" => "redacted_failure"
    })
  end

  defp exact_replay_result(%{attempt: %Attempt{result_digest: nil}}), do: :ok

  defp exact_replay_result(%{attempt: %Attempt{result_digest: expected}, command: command}) do
    with {:ok, actual} <- result_digest(command),
         true <- secure_equal?(actual, expected) do
      :ok
    else
      _ -> {:error, :secure_execution_replay_result_mismatch}
    end
  end

  defp attempt_state(%Attempt{state: state}) when state in [:succeeded, :failed, :ambiguous],
    do: :terminal

  defp attempt_state(%Attempt{}), do: :active

  defp exact_keys(map, keys) do
    if MapSet.new(Map.keys(map)) == MapSet.new(keys),
      do: :ok,
      else: {:error, :unexpected_secure_execution_result_field}
  end

  defp stringify(map) when is_map(map),
    do: Map.new(map, fn {key, item} -> {to_string(key), item} end)

  defp stringify(_map), do: %{}

  defp required({:ok, nil}, error), do: {:error, error}
  defp required({:ok, value}, _error), do: {:ok, value}
  defp required({:error, reason}, _error), do: {:error, reason}

  defp uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, normalized} -> {:ok, normalized}
      :error -> {:error, :invalid_secure_execution_command_id}
    end
  end

  defp uuid(_value), do: {:error, :invalid_secure_execution_command_id}

  defp attempt_store(opts), do: Keyword.get(opts, :attempt_store, Attempt)

  defp transaction(opts, fun) do
    case Keyword.get(opts, :transaction) do
      callback when is_function(callback, 1) -> callback.(fun)
      _callback -> Repo.transaction(fun)
    end
  end

  defp rollback(opts, reason) do
    case Keyword.get(opts, :rollback) do
      callback when is_function(callback, 1) -> callback.(reason)
      _callback -> Repo.rollback(reason)
    end
  end

  defp lifecycle_opts(opts, key, base \\ []) do
    case Keyword.get(opts, key) do
      nil -> base
      actions -> Keyword.put(base, :actions, actions)
    end
  end

  defp now(opts),
    do: opts |> Keyword.get(:now, DateTime.utc_now()) |> DateTime.truncate(:microsecond)

  defp error_code(reason), do: SafeFailureEvidence.code(reason)

  defp same_id?(left, right), do: to_string(left) == to_string(right)

  defp secure_equal?(left, right)
       when is_binary(left) and is_binary(right) and byte_size(left) == byte_size(right),
       do: Plug.Crypto.secure_compare(left, right)

  defp secure_equal?(_left, _right), do: false

  defp nonempty?(value), do: is_binary(value) and String.trim(value) != ""
  defp safe_id(value) when is_binary(value), do: String.slice(value, 0, 64)
  defp safe_id(_value), do: nil
  defp value(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp value(_map, _key), do: nil
end
