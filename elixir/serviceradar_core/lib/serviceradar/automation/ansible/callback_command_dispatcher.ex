defmodule ServiceRadar.Automation.Ansible.CallbackCommandDispatcher do
  @moduledoc """
  Claims and dispatches one durable callback command attempt.

  Dispatch is allowed only after rebuilding the command from immutable server
  state and matching both stored digests. A preallocated command UUID closes
  the crash window: recovery dispatches only when that `AgentCommand` does not
  already exist and a lease CAS succeeds.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Automation.Ansible.AutomationCallbackCommandAttempt, as: Attempt
  alias ServiceRadar.Automation.Ansible.AutomationExecution
  alias ServiceRadar.Automation.Ansible.AutomationExecutionTarget
  alias ServiceRadar.Automation.Ansible.AutomationOperation
  alias ServiceRadar.Automation.Ansible.AwxClient
  alias ServiceRadar.Automation.Ansible.AwxLaunchPreflightAttestation
  alias ServiceRadar.Automation.Ansible.CallbackCommandContract
  alias ServiceRadar.Automation.Ansible.Controller
  alias ServiceRadar.Automation.Ansible.ControllerSecuritySnapshot
  alias ServiceRadar.Automation.Ansible.SafeFailureEvidence
  alias ServiceRadar.Automation.Ansible.SecureExecutionLifecycle
  alias ServiceRadar.Automation.CallbackGrants.AshStore, as: GrantStore
  alias ServiceRadar.Automation.CallbackGrants.Lifecycle
  alias ServiceRadar.Automation.CallbackGrants.Runtime
  alias ServiceRadar.Edge.AgentCommand
  alias ServiceRadar.Edge.AgentCommandBus

  @actor SystemActor.system(:automation_callback_command_dispatcher)
  @lease_seconds 15

  @spec dispatch(Attempt.t(), keyword()) :: {:ok, atom()} | {:error, term()}
  def dispatch(attempt, opts \\ [])

  def dispatch(%Attempt{} = attempt, opts) do
    now = now(opts)

    with :ok <- before_deadline(attempt, now),
         {:ok, resources} <- load_resources(attempt, opts),
         :ok <- validate_resource_principal(attempt, resources),
         :ok <- verify_controller_boundary(attempt, resources, now, opts),
         :ok <- validate_cleanup_only_stage(attempt),
         {:ok, request} <- rebuild_request(attempt, resources),
         true <-
           CallbackCommandContract.request_matches?(attempt, request) ||
             {:error, :callback_command_request_digest_mismatch},
         context = CallbackCommandContract.context(attempt, resources.execution),
         true <-
           CallbackCommandContract.context_matches?(attempt, resources.execution, context) ||
             {:error, :callback_command_context_digest_mismatch},
         :ok <- authorize_privileged_continuation(attempt, resources, opts),
         :ok <- verify_preflight_before_mutation(attempt, resources, now, opts),
         {:ok, claimed, lease_token} <- claim(attempt, now, opts) do
      dispatch_claimed(claimed, lease_token, resources, request, context, now, opts)
    else
      false ->
        {:error, :callback_command_contract_mismatch}

      {:error, {:callback_current_authority_denied, reason}} ->
        handle_authority_denial(attempt, reason, now, opts)

      {:error, _reason} = error ->
        error
    end
  rescue
    _ -> {:error, :callback_command_dispatch_unavailable}
  catch
    _, _ -> {:error, :callback_command_dispatch_unavailable}
  end

  def dispatch(_attempt, _opts), do: {:error, :invalid_callback_command_attempt}

  @doc "Reauthorizes a known in-flight callback child without redispatching its command."
  @spec reauthorize_continuation(Attempt.t(), keyword()) :: :ok | {:error, term()}
  def reauthorize_continuation(attempt, opts \\ [])

  def reauthorize_continuation(%Attempt{} = attempt, opts) when is_list(opts) do
    case authority_mode(attempt) do
      mode when mode in [:pending_job, :watchdog] ->
        now = now(opts)

        with {:ok, resources} <- load_resources(attempt, opts),
             :ok <- validate_resource_principal(attempt, resources),
             :ok <- verify_controller_boundary(attempt, resources, now, opts),
             :ok <- authorize_callback(mode, resources, opts) do
          :ok
        else
          {:error, {:callback_current_authority_denied, reason}} ->
            handle_authority_denial(attempt, reason, now, opts)

          {:error, _reason} = error ->
            error
        end

      _mode ->
        :ok
    end
  rescue
    _ -> {:error, :callback_continuation_reauthorization_unavailable}
  catch
    _, _ -> {:error, :callback_continuation_reauthorization_unavailable}
  end

  def reauthorize_continuation(_attempt, _opts), do: {:error, :invalid_callback_command_attempt}

  defp load_resources(attempt, opts) do
    loader = Keyword.get(opts, :resource_loader, &load_persisted_resources/1)

    if is_function(loader, 1),
      do: loader.(attempt),
      else: {:error, :callback_command_resource_loader_unavailable}
  end

  defp load_persisted_resources(attempt) do
    with {:ok, %AutomationOperation{} = operation} <-
           required(AutomationOperation.get_by_id(attempt.operation_id, actor: @actor)),
         {:ok, %AutomationExecution{} = execution} <-
           required(AutomationExecution.get_by_id(attempt.execution_id, actor: @actor)),
         {:ok, %Controller{} = controller} <-
           required(Controller.get_by_id(attempt.controller_id, actor: @actor)),
         {:ok, grant} <- GrantStore.fetch(attempt.grant_id, nil),
         {:ok, targets} <-
           AutomationExecutionTarget.list_for_execution(attempt.execution_id, actor: @actor),
         true <-
           controller.agent_id == attempt.dispatch_agent_id ||
             {:error, :callback_command_controller_agent_mismatch} do
      {:ok,
       %{
         operation: operation,
         execution: execution,
         controller: controller,
         grant: grant,
         targets: targets
       }}
    else
      false -> {:error, :callback_command_resource_mismatch}
      {:error, _reason} = error -> error
    end
  end

  # Resource loaders are injectable for tests, but no loader is an authority
  # boundary. The durable attempt, controller, and callback grant must all bind
  # the exact edge principal tuple before any authorization or dispatch occurs.
  defp validate_resource_principal(attempt, resources) when is_map(resources) do
    controller_agent_id = resources |> value(:controller) |> value(:agent_id)
    grant = value(resources, :grant)

    if same_nonempty_identifier?(controller_agent_id, attempt.dispatch_agent_id) and
         same_nonempty_identifier?(value(grant, :dispatch_agent_id), attempt.dispatch_agent_id) and
         same_nonempty_identifier?(
           value(grant, :dispatch_partition_id),
           attempt.dispatch_partition_id
         ) do
      :ok
    else
      {:error, :callback_command_resource_principal_mismatch}
    end
  end

  defp validate_resource_principal(_attempt, _resources),
    do: {:error, :callback_command_resource_principal_mismatch}

  # New plans carry a create-only attestation on both durable resources. It is
  # checked for every non-mutating continuation, while mutation stages defer
  # the same full check until immediately before a lease can be claimed. That
  # preserves current-authority denial handling without letting a launch or
  # credential creation reach the command bus without evidence.
  #
  # Existing rows predate the attestation fields (their JSON snapshot is the
  # migration's empty default). They retain the old controller snapshot path
  # only for non-launch work; `verify_preflight_before_mutation/4` prevents a
  # legacy/digest-only row from entering either mutation stage.
  defp verify_controller_boundary(attempt, resources, now, opts) do
    cond do
      immutable_preflight_present?(resources) and preflight_mutation_stage?(attempt) ->
        :ok

      immutable_preflight_present?(resources) ->
        verify_immutable_preflight(attempt, resources, now, opts)

      true ->
        verify_legacy_controller_boundary(attempt, resources)
    end
  end

  defp verify_preflight_before_mutation(attempt, resources, now, opts) do
    if preflight_mutation_stage?(attempt),
      do: verify_immutable_preflight(attempt, resources, now, opts),
      else: :ok
  end

  defp verify_immutable_preflight(attempt, resources, now, opts) do
    verification_opts = preflight_verification_opts(opts)

    case AwxLaunchPreflightAttestation.verify_persisted(
           value(resources, :operation),
           value(resources, :execution),
           value(resources, :controller),
           now,
           verification_opts
         ) do
      {:ok, snapshot} ->
        verify_preflight_dispatch_principal(snapshot, attempt)

      {:error, :awx_preflight_evidence_expired} = error ->
        if preflight_mutation_stage?(attempt) do
          error
        else
          with {:ok, snapshot} <-
                 AwxLaunchPreflightAttestation.verify_persisted_for_cleanup(
                   value(resources, :operation),
                   value(resources, :execution),
                   value(resources, :controller),
                   now,
                   verification_opts
                 ) do
            verify_preflight_dispatch_principal(snapshot, attempt)
          end
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp verify_preflight_dispatch_principal(snapshot, attempt) do
    AwxLaunchPreflightAttestation.verify_dispatch_principal(
      snapshot,
      attempt.dispatch_agent_id,
      attempt.dispatch_partition_id
    )
  end

  defp verify_legacy_controller_boundary(attempt, resources) do
    metadata = value(resources.execution, :metadata) || %{}

    with partition when is_binary(partition) and partition != "" <-
           value(metadata, :dispatch_partition_id),
         true <- partition == attempt.dispatch_partition_id,
         :ok <-
           ControllerSecuritySnapshot.verify(
             resources.controller,
             value(metadata, :controller_security_snapshot)
           ) do
      :ok
    else
      false -> {:error, :callback_dispatch_partition_drift}
      {:error, _reason} = error -> error
      _ -> {:error, :callback_dispatch_partition_required}
    end
  end

  defp immutable_preflight_present?(resources) when is_map(resources) do
    Enum.any?([value(resources, :operation), value(resources, :execution)], fn resource ->
      snapshot = value(resource, :immutable_launch_snapshot)

      not is_nil(value(resource, :preflight_evidence_id)) or
        not is_nil(value(resource, :immutable_launch_snapshot_digest)) or
        (is_map(snapshot) and map_size(snapshot) > 0)
    end)
  end

  defp immutable_preflight_present?(_resources), do: false

  defp preflight_mutation_stage?(%Attempt{stage: stage})
       when stage in [:create_credential, :launch_job], do: true

  defp preflight_mutation_stage?(_attempt), do: false

  defp preflight_verification_opts(opts) do
    case Keyword.fetch(opts, :preflight_evidence_reader) do
      {:ok, reader} -> [evidence_reader: reader]
      :error -> []
    end
  end

  defp validate_cleanup_only_stage(%Attempt{cleanup_only: false}), do: :ok

  defp validate_cleanup_only_stage(%Attempt{cleanup_only: true, stage: stage})
       when stage in [
              :fetch_credential,
              :fetch_job,
              :list_recent_jobs,
              :fetch_host_summaries,
              :cancel_job,
              :delete_credential
            ],
       do: :ok

  defp validate_cleanup_only_stage(%Attempt{cleanup_only: true}),
    do: {:error, :callback_cleanup_only_side_effect_forbidden}

  defp rebuild_request(%Attempt{stage: :create_credential}, resources) do
    CallbackCommandContract.create_credential_request(
      resources.execution,
      resources.grant.awx_scope_snapshot,
      resources.grant.launch_envelope_ref
    )
  end

  defp rebuild_request(%Attempt{stage: :fetch_credential}, resources) do
    CallbackCommandContract.credential_lookup_request(
      resources.execution,
      resources.grant.awx_scope_snapshot
    )
  end

  defp rebuild_request(%Attempt{stage: :launch_job} = attempt, resources) do
    CallbackCommandContract.launch_request(
      resources.operation,
      resources.execution,
      attempt.expected_credential_id
    )
  end

  defp rebuild_request(%Attempt{stage: :fetch_job} = attempt, _resources),
    do: CallbackCommandContract.fetch_job_request(attempt.expected_job_id)

  defp rebuild_request(%Attempt{stage: :fetch_host_summaries} = attempt, resources) do
    target_count =
      resources.grant.awx_scope_snapshot |> value(:targets) |> List.wrap() |> length()

    CallbackCommandContract.host_summaries_request(attempt.expected_job_id, target_count)
  end

  defp rebuild_request(%Attempt{stage: :list_recent_jobs} = attempt, resources),
    do: CallbackCommandContract.recent_jobs_request(resources.execution, attempt.reconcile_after)

  defp rebuild_request(%Attempt{stage: :cancel_job} = attempt, _resources),
    do: CallbackCommandContract.cancel_job_request(attempt.expected_job_id)

  defp rebuild_request(_attempt, _resources),
    do: {:error, :callback_command_stage_not_dispatchable}

  defp authorize_privileged_continuation(attempt, resources, opts) do
    case authority_mode(attempt) do
      nil -> :ok
      mode -> authorize_callback(mode, resources, opts)
    end
  end

  defp authority_mode(%Attempt{stage: :create_credential}), do: :credential_creation
  defp authority_mode(%Attempt{stage: :launch_job}), do: :launch

  defp authority_mode(%Attempt{stage: :fetch_job, purpose: purpose})
       when purpose in [:accepted_job_proof, :scope_poll],
       do: :pending_job

  defp authority_mode(%Attempt{stage: :fetch_host_summaries, purpose: :host_scope_proof}),
    do: :pending_job

  defp authority_mode(%Attempt{stage: :fetch_job, purpose: :terminal_poll}), do: :watchdog

  defp authority_mode(%Attempt{stage: :fetch_host_summaries, purpose: :terminal_confirmation}),
    do: :watchdog

  # Launch reconciliation is allowed to discover an otherwise orphaned child;
  # once its job ID is known, the accepted-job proof is reauthorized and a
  # contraction routes through durable cancellation instead of activation.
  defp authority_mode(_attempt), do: nil

  defp authorize_callback(mode, resources, opts) do
    authorizer = Keyword.get(opts, :callback_authorizer, &authorize_callback_with_lifecycle/3)

    case authorizer.(mode, resources.grant, opts) do
      :ok -> :ok
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, {:callback_current_authority_denied, reason}}
      _ -> {:error, {:callback_current_authority_denied, :current_authority_required}}
    end
  end

  defp authorize_callback_with_lifecycle(mode, grant, opts) do
    with {:ok, lifecycle_opts} <- callback_lifecycle_opts(opts) do
      case mode do
        :credential_creation ->
          Lifecycle.reauthorize_credential_creation(value(grant, :id), lifecycle_opts)

        :launch ->
          Lifecycle.authorize_launch_dispatch(value(grant, :id), lifecycle_opts)

        :pending_job ->
          Lifecycle.reauthorize_pending_job(value(grant, :id), lifecycle_opts)

        :watchdog ->
          Lifecycle.reauthorize_watchdog(value(grant, :id), lifecycle_opts)
      end
    end
  end

  defp callback_lifecycle_opts(opts) do
    case Keyword.fetch(opts, :lifecycle_opts) do
      {:ok, lifecycle_opts} when is_list(lifecycle_opts) -> {:ok, lifecycle_opts}
      _ -> Runtime.internal_opts()
    end
  end

  defp resources_for_denial(attempt, opts) do
    case load_resources(attempt, opts) do
      {:ok, resources} -> resources
      _ -> nil
    end
  end

  defp handle_authority_denial(attempt, reason, now, opts) do
    case record_authority_denial(
           attempt,
           resources_for_denial(attempt, opts),
           reason,
           now,
           opts
         ) do
      :ok ->
        {:error, reason}

      {:error, marker_reason} ->
        {:error,
         {:callback_authority_denial_persistence_failed, SafeFailureEvidence.code(marker_reason)}}
    end
  end

  defp record_authority_denial(attempt, resources, reason, now, opts) when is_map(resources) do
    lifecycle_result =
      case attempt.stage do
        stage when stage in [:create_credential, :launch_job] ->
          mark_prelaunch_denied(resources, reason, now, opts)

        _known_child ->
          mark_active_contraction(resources, reason, opts)
      end

    marker = Keyword.get(opts, :authority_denial_marker, &mark_authority_denied_persisted/4)

    with :ok <- normalize_denial_result(lifecycle_result) do
      normalize_denial_result(marker.(attempt, reason, now, opts))
    end
  end

  defp record_authority_denial(_attempt, _resources, _reason, _now, _opts),
    do: {:error, :callback_authority_denial_resources_unavailable}

  defp mark_prelaunch_denied(resources, _reason, now, opts) do
    marker =
      Keyword.get(opts, :prelaunch_denial_handler, fn %{
                                                        operation: operation,
                                                        execution: execution
                                                      } ->
        diagnostics = %{"reason_code" => "current_authority_denied"}

        with {:ok, _execution} <-
               AutomationExecution.record_state(
                 execution,
                 %{state: :failed, ended_at: now, diagnostics: diagnostics},
                 actor: @actor
               ),
             {:ok, _operation} <-
               AutomationOperation.record_state(
                 operation,
                 %{state: :failed, ended_at: now, diagnostics: diagnostics},
                 actor: @actor
               ) do
          :ok
        end
      end)

    marker.(resources)
  end

  defp mark_active_contraction(resources, reason, opts) do
    handler =
      Keyword.get(opts, :active_contraction_handler, fn resources, reason ->
        SecureExecutionLifecycle.fail_closed(
          resources.operation,
          resources.execution,
          resources.targets,
          :cancel_failed,
          reason,
          cancel_required: true
        )
      end)

    handler.(resources, reason)
  end

  defp mark_authority_denied_persisted(attempt, reason, now, _opts) do
    Attempt.deny_incomplete(
      attempt,
      %{
        processed_at: now,
        outcome_code: "current_authority_denied",
        last_error_code: SafeFailureEvidence.code(reason)
      },
      actor: @actor
    )
  end

  defp normalize_denial_result(:ok), do: :ok
  defp normalize_denial_result({:ok, _result}), do: :ok
  defp normalize_denial_result({:error, _reason} = error), do: error
  defp normalize_denial_result(_result), do: {:error, :callback_authority_denial_unconfirmed}

  defp claim(attempt, now, opts) do
    lease_token = Ecto.UUID.generate()
    lease_expires_at = DateTime.add(now, @lease_seconds, :second)
    claimer = Keyword.get(opts, :claim, &claim_persisted/4)

    case claimer.(attempt, lease_token, lease_expires_at, now) do
      {:ok, claimed} -> {:ok, claimed, lease_token}
      {:error, reason} -> {:error, {:callback_command_claim_failed, reason}}
    end
  end

  defp claim_persisted(attempt, lease_token, lease_expires_at, now) do
    Attempt.claim_dispatch(
      attempt,
      %{lease_token: lease_token, lease_expires_at: lease_expires_at, now: now},
      actor: @actor
    )
  end

  defp dispatch_claimed(attempt, lease_token, resources, request, context, now, opts) do
    dispatcher = Keyword.get(opts, :awx_dispatcher, &dispatch_awx/5)

    case dispatcher.(attempt, resources.controller, request, context, opts) do
      {:ok, command} ->
        with :ok <- exact_command_id(command, attempt.command_id) do
          mark_dispatched_replay_safe(attempt, lease_token, now, opts)
        end

      {:error, reason} ->
        reconcile_dispatch_error(
          attempt,
          lease_token,
          reason,
          resources,
          request,
          context,
          now,
          opts
        )
    end
  end

  defp dispatch_awx(
         %Attempt{stage: :create_credential} = attempt,
         controller,
         request,
         context,
         opts
       ) do
    AwxClient.create_callback_credential(controller, request.binding,
      command_id: attempt.command_id,
      required_partition: attempt.dispatch_partition_id,
      callback_command_attempt: true,
      source: :automation,
      context: context,
      command_bus: Keyword.get(opts, :command_bus, AgentCommandBus)
    )
  end

  defp dispatch_awx(%Attempt{stage: :launch_job} = attempt, controller, request, context, opts) do
    AwxClient.launch_job(controller, request.template_id, request.launch_opts,
      command_id: attempt.command_id,
      required_partition: attempt.dispatch_partition_id,
      callback_command_attempt: true,
      source: :automation,
      context: context,
      command_bus: Keyword.get(opts, :command_bus, AgentCommandBus)
    )
  end

  defp dispatch_awx(
         %Attempt{stage: :fetch_credential} = attempt,
         controller,
         request,
         context,
         opts
       ) do
    AwxClient.fetch_callback_credential(controller, request,
      command_id: attempt.command_id,
      required_partition: attempt.dispatch_partition_id,
      callback_command_attempt: true,
      source: :automation,
      context: context,
      command_bus: Keyword.get(opts, :command_bus, AgentCommandBus)
    )
  end

  defp dispatch_awx(%Attempt{stage: :fetch_job} = attempt, controller, request, context, opts) do
    AwxClient.fetch_job(controller, request.job_id,
      command_id: attempt.command_id,
      required_partition: attempt.dispatch_partition_id,
      callback_command_attempt: true,
      source: :automation,
      context: context,
      command_bus: Keyword.get(opts, :command_bus, AgentCommandBus)
    )
  end

  defp dispatch_awx(
         %Attempt{stage: :fetch_host_summaries} = attempt,
         controller,
         request,
         context,
         opts
       ) do
    AwxClient.fetch_job_host_summaries(controller, request.job_id, request.max_hosts,
      command_id: attempt.command_id,
      required_partition: attempt.dispatch_partition_id,
      callback_command_attempt: true,
      source: :automation,
      context: context,
      command_bus: Keyword.get(opts, :command_bus, AgentCommandBus)
    )
  end

  defp dispatch_awx(
         %Attempt{stage: :list_recent_jobs} = attempt,
         controller,
         request,
         context,
         opts
       ) do
    AwxClient.list_recent_jobs(controller, request,
      command_id: attempt.command_id,
      required_partition: attempt.dispatch_partition_id,
      callback_command_attempt: true,
      source: :automation,
      context: context,
      command_bus: Keyword.get(opts, :command_bus, AgentCommandBus)
    )
  end

  defp dispatch_awx(%Attempt{stage: :cancel_job} = attempt, controller, request, context, opts) do
    AwxClient.cancel_job(controller, request.job_id,
      command_id: attempt.command_id,
      required_partition: attempt.dispatch_partition_id,
      callback_command_attempt: true,
      source: :automation,
      context: context,
      command_bus: Keyword.get(opts, :command_bus, AgentCommandBus)
    )
  end

  defp dispatch_awx(_attempt, _controller, _request, _context, _opts),
    do: {:error, :callback_command_stage_not_dispatchable}

  defp reconcile_dispatch_error(
         attempt,
         lease_token,
         reason,
         resources,
         request,
         context,
         now,
         opts
       ) do
    case fetch_command(attempt.command_id, opts) do
      {:ok, %AgentCommand{} = command} ->
        if exact_persisted_command?(command, attempt, resources, request, context) do
          with {:ok, outcome} <- mark_dispatched_replay_safe(attempt, lease_token, now, opts) do
            {:ok,
             if(outcome == :dispatched,
               do: :persisted_for_recovery,
               else: outcome
             )}
          end
        else
          {:error, :callback_command_persisted_correlation_mismatch}
        end

      {:ok, nil} ->
        release_dispatch(attempt, lease_token, reason, now, opts)

      {:error, _fetch_reason} ->
        {:error, :callback_command_dispatch_persistence_ambiguous}
    end
  end

  defp fetch_command(command_id, opts) do
    fetcher = Keyword.get(opts, :command_fetcher, &fetch_persisted_command/1)
    fetcher.(command_id)
  end

  defp fetch_persisted_command(command_id), do: AgentCommand.get_by_id(command_id, actor: @actor)

  defp mark_dispatched(attempt, lease_token, now, opts) do
    marker = Keyword.get(opts, :mark_dispatched, &mark_dispatched_persisted/3)
    marker.(attempt, lease_token, now)
  end

  # The agent can finish a fast command while the dispatch call is still
  # returning. In that race the result coordinator legitimately takes the
  # processing lease first, so a failed dispatch-state CAS is not a transport
  # failure and must not revoke the grant.
  defp mark_dispatched_replay_safe(attempt, lease_token, now, opts) do
    case mark_dispatched(attempt, lease_token, now, opts) do
      {:ok, _updated} ->
        {:ok, :dispatched}

      {:error, mark_reason} ->
        case fetch_attempt(attempt.id, opts) do
          {:ok, %Attempt{command_id: command_id, state: state}}
          when state in [:processing, :succeeded, :failed, :ambiguous] ->
            if same_identifier?(command_id, attempt.command_id),
              do: {:ok, :result_already_processing},
              else: {:error, :callback_command_attempt_correlation_mismatch}

          {:ok, _other} ->
            {:error, {:callback_command_mark_dispatched_failed, mark_reason}}

          {:error, fetch_reason} ->
            {:error, {:callback_command_mark_dispatched_state_unknown, mark_reason, fetch_reason}}
        end
    end
  end

  defp fetch_attempt(attempt_id, opts) do
    fetcher = Keyword.get(opts, :attempt_fetcher, &fetch_persisted_attempt/1)
    fetcher.(attempt_id)
  end

  defp fetch_persisted_attempt(attempt_id), do: Attempt.get_by_id(attempt_id, actor: @actor)

  defp mark_dispatched_persisted(attempt, lease_token, now) do
    Attempt.mark_dispatched(
      attempt,
      %{
        lease_token: lease_token,
        dispatched_at: now,
        next_attempt_at: DateTime.add(now, 1, :second)
      },
      actor: @actor
    )
  end

  defp release_dispatch(attempt, lease_token, reason, now, opts) do
    releaser = Keyword.get(opts, :release_dispatch, &release_dispatch_persisted/4)
    next_attempt_at = DateTime.add(now, 1, :second)

    case releaser.(attempt, lease_token, next_attempt_at, error_code(reason)) do
      {:ok, _updated} -> {:ok, :deferred}
      {:error, release_reason} -> {:error, {:callback_command_release_failed, release_reason}}
    end
  end

  defp release_dispatch_persisted(attempt, lease_token, next_attempt_at, error_code) do
    Attempt.release_dispatch(
      attempt,
      %{
        lease_token: lease_token,
        next_attempt_at: next_attempt_at,
        last_error_code: error_code
      },
      actor: @actor
    )
  end

  defp exact_persisted_command?(command, attempt, resources, request, context) do
    same_identifier?(command.id, attempt.command_id) and
      command.command_type == attempt.command_type and
      command.agent_id == attempt.dispatch_agent_id and
      command.partition_id == attempt.dispatch_partition_id and
      value(resources.grant, :dispatch_partition_id) == attempt.dispatch_partition_id and
      CallbackCommandContract.context_matches?(
        attempt,
        resources.execution,
        command.context || %{}
      ) and
      command.context == context and
      CallbackCommandContract.persisted_payload_matches?(
        attempt,
        resources.execution,
        resources.controller,
        request,
        command.payload || %{}
      )
  end

  defp exact_command_id(command_id, expected) when is_binary(command_id),
    do: if(same_identifier?(command_id, expected), do: :ok, else: {:error, :command_id_mismatch})

  defp exact_command_id(%{id: command_id}, expected), do: exact_command_id(command_id, expected)
  defp exact_command_id(_command, _expected), do: {:error, :command_id_missing}

  defp before_deadline(attempt, now) do
    if DateTime.before?(now, attempt.deadline_at),
      do: :ok,
      else: {:error, :callback_command_deadline_elapsed}
  end

  defp required({:ok, nil}), do: {:error, :callback_command_resource_not_found}
  defp required({:ok, value}), do: {:ok, value}
  defp required({:error, reason}), do: {:error, reason}

  defp error_code(reason), do: SafeFailureEvidence.code(reason)

  defp now(opts),
    do: opts |> Keyword.get(:now, DateTime.utc_now()) |> DateTime.truncate(:microsecond)

  defp same_identifier?(left, right), do: to_string(left) == to_string(right)

  defp same_nonempty_identifier?(left, right) when is_binary(left) and is_binary(right),
    do: left != "" and right != "" and left == right

  defp same_nonempty_identifier?(_left, _right), do: false

  defp value(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp value(_map, _key), do: nil
end
