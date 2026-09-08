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
  alias ServiceRadar.Automation.Ansible.AwxLaunchPreflightAttestation
  alias ServiceRadar.Automation.Ansible.CallbackCommandContract
  alias ServiceRadar.Automation.Ansible.CallbackCommandDispatcher
  alias ServiceRadar.Automation.Ansible.Controller
  alias ServiceRadar.Automation.Ansible.ControllerProvenance
  alias ServiceRadar.Automation.Ansible.ControllerSecuritySnapshot
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
  @max_recent_candidates 5_000
  @command_types [
    "awx.create_callback_credential",
    "awx.fetch_callback_credential",
    "awx.launch_job",
    "awx.fetch_job",
    "awx.list_recent_jobs",
    "awx.fetch_job_host_summaries",
    "awx.cancel_job"
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
    authenticated_partition_id = value(data, :partition_id)

    if command_type in @command_types do
      with {:ok, command_id} <- uuid(command_id),
           true <- nonempty?(authenticated_agent_id) || {:error, :authenticated_agent_required},
           true <-
             nonempty?(authenticated_partition_id) ||
               {:error, :authenticated_partition_required} do
        process_persisted(
          command_id,
          authenticated_agent_id,
          command_type,
          Keyword.put(opts, :authenticated_partition_id, authenticated_partition_id)
        )
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
           exact_authenticated_provenance(
             bundle,
             authenticated_agent_id,
             reported_command_type,
             opts
           ),
         {:ok, boundary} <- verify_controller_boundary(bundle, now, opts),
         :ok <- terminal_command(bundle.command) do
      bundle = Map.put(bundle, :controller_boundary, boundary)
      process_terminal_bundle(bundle, now, apply_boundary_policy(opts, boundary))
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
         {:ok, boundary} <- verify_controller_boundary(bundle, now, opts),
         {:ok, claimed, token} <- claim_processing(bundle.attempt, now, opts) do
      bundle = %{bundle | attempt: claimed, controller_boundary: boundary}
      reconcile_claimed_transport(bundle, token, now, apply_boundary_policy(opts, boundary))
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

  defp exact_authenticated_provenance(bundle, authenticated_agent_id, reported_type, opts) do
    authenticated_partition_id = Keyword.get(opts, :authenticated_partition_id)

    cond do
      bundle.command.agent_id != authenticated_agent_id ->
        {:error, :callback_result_authenticated_agent_mismatch}

      bundle.attempt.dispatch_agent_id != authenticated_agent_id ->
        {:error, :callback_result_attempt_agent_mismatch}

      bundle.command.partition_id != bundle.attempt.dispatch_partition_id ->
        {:error, :callback_result_authenticated_partition_mismatch}

      nonempty?(authenticated_partition_id) and
          authenticated_partition_id != bundle.attempt.dispatch_partition_id ->
        {:error, :callback_result_authenticated_partition_mismatch}

      value(bundle.grant, :dispatch_agent_id) != bundle.attempt.dispatch_agent_id ->
        {:error, :callback_result_grant_agent_mismatch}

      value(bundle.grant, :dispatch_partition_id) != bundle.attempt.dispatch_partition_id ->
        {:error, :callback_result_grant_partition_mismatch}

      bundle.command.command_type != reported_type ->
        {:error, :callback_result_reported_type_mismatch}

      true ->
        :ok
    end
  end

  # Fresh callback executions are anchored to the immutable, independently
  # evidenced launch preflight. The raw controller snapshot used for later
  # read-only provenance is reconstructed from the current controller only
  # after its digest is verified against that immutable attestation; mutable
  # execution metadata is never an authority for a new callback child.
  #
  # Older rows retain the prior metadata boundary solely so already-created
  # credentials/jobs can be contained. `apply_boundary_policy/2` forces those
  # paths into cleanup-only processing, preventing a digest-only legacy row
  # from ever creating a follow-up `awx.launch_job` command.
  defp verify_controller_boundary(bundle, now, opts) do
    if immutable_preflight_present?(bundle) do
      verify_attested_controller_boundary(bundle, now, opts)
    else
      verify_legacy_cleanup_boundary(bundle)
    end
  end

  defp verify_attested_controller_boundary(bundle, now, opts) do
    verification_opts = preflight_verification_opts(opts)

    case AwxLaunchPreflightAttestation.verify_persisted(
           bundle.operation,
           bundle.execution,
           bundle.controller,
           now,
           verification_opts
         ) do
      {:ok, attestation} ->
        verified_attested_controller_boundary(bundle, attestation, :attested)

      # The mutation was already issued. Keep the evidence/controller/edge
      # boundary intact, but route every later action through cleanup-only so
      # expiry cannot authorize a new credential or job launch.
      {:error, :awx_preflight_evidence_expired} ->
        with {:ok, attestation} <-
               AwxLaunchPreflightAttestation.verify_persisted_for_cleanup(
                 bundle.operation,
                 bundle.execution,
                 bundle.controller,
                 now,
                 verification_opts
               ) do
          verified_attested_controller_boundary(bundle, attestation, :attested_cleanup)
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp verified_attested_controller_boundary(bundle, attestation, mode) do
    with :ok <-
           AwxLaunchPreflightAttestation.verify_dispatch_principal(
             attestation,
             bundle.attempt.dispatch_agent_id,
             bundle.attempt.dispatch_partition_id
           ),
         :ok <- exact_boundary_dispatch(bundle, attestation["dispatch_partition_id"]),
         {:ok, controller_security_snapshot} <-
           ControllerSecuritySnapshot.capture(bundle.controller) do
      {:ok,
       %{
         mode: mode,
         dispatch_partition_id: attestation["dispatch_partition_id"],
         controller_security_snapshot: controller_security_snapshot
       }}
    end
  end

  defp verify_legacy_cleanup_boundary(bundle) do
    metadata = value(bundle.execution, :metadata) || %{}

    with partition when is_binary(partition) and partition != "" <-
           value(metadata, :dispatch_partition_id),
         :ok <- exact_boundary_dispatch(bundle, partition),
         :ok <-
           ControllerSecuritySnapshot.verify(
             bundle.controller,
             value(metadata, :controller_security_snapshot)
           ) do
      {:ok,
       %{
         mode: :legacy_cleanup,
         dispatch_partition_id: partition,
         controller_security_snapshot: value(metadata, :controller_security_snapshot)
       }}
    else
      false -> {:error, :callback_controller_security_boundary_drift}
      {:error, _reason} = error -> error
      _ -> {:error, :callback_dispatch_partition_required}
    end
  end

  defp exact_boundary_dispatch(bundle, partition) do
    command = value(bundle, :command) || %{}
    attempt = value(bundle, :attempt) || %{}
    grant = value(bundle, :grant) || %{}

    cond do
      not is_binary(partition) or partition == "" ->
        {:error, :callback_dispatch_partition_required}

      partition != value(attempt, :dispatch_partition_id) ->
        {:error, :callback_controller_security_boundary_drift}

      partition != value(command, :partition_id) ->
        {:error, :callback_controller_security_boundary_drift}

      partition != value(grant, :dispatch_partition_id) ->
        {:error, :callback_controller_security_boundary_drift}

      value(bundle.controller, :agent_id) != value(attempt, :dispatch_agent_id) ->
        {:error, :callback_controller_security_boundary_drift}

      value(command, :agent_id) != value(attempt, :dispatch_agent_id) ->
        {:error, :callback_controller_security_boundary_drift}

      value(grant, :dispatch_agent_id) != value(attempt, :dispatch_agent_id) ->
        {:error, :callback_controller_security_boundary_drift}

      true ->
        :ok
    end
  end

  defp immutable_preflight_present?(bundle) when is_map(bundle) do
    Enum.any?([value(bundle, :operation), value(bundle, :execution)], fn resource ->
      snapshot = value(resource, :immutable_launch_snapshot)

      not is_nil(value(resource, :preflight_evidence_id)) or
        not is_nil(value(resource, :immutable_launch_snapshot_digest)) or
        (is_map(snapshot) and map_size(snapshot) > 0)
    end)
  end

  defp immutable_preflight_present?(_bundle), do: false

  defp apply_boundary_policy(opts, %{mode: mode})
       when mode in [:attested_cleanup, :legacy_cleanup],
       do: Keyword.put(opts, :cleanup_only, true)

  defp apply_boundary_policy(opts, _boundary), do: opts

  defp preflight_verification_opts(opts) do
    case Keyword.fetch(opts, :preflight_evidence_reader) do
      {:ok, reader} -> [evidence_reader: reader]
      :error -> []
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
        with {:ok, next_attrs, outcome} <-
               reconciliation_attempt_attrs_for_boundary(bundle, now, opts),
             {:ok, next} <-
               ambiguous_with_next(bundle.attempt, token, nil, outcome, next_attrs, now),
             :ok <- dispatch_after_commit(next, opts) do
          {:ok, outcome}
        end

      {:error, reason} ->
        finish_fail_closed(bundle, token, nil, reason, now, opts)
    end
  end

  defp reconciliation_attempt_attrs_for_boundary(bundle, now, opts) do
    if cleanup_only?(bundle, opts) do
      cleanup_reconciliation_attempt_attrs(bundle, now, opts)
    else
      reconciliation_attempt_attrs(bundle, now)
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

  defp rebuild_request(%{attempt: %Attempt{stage: :cancel_job}} = bundle),
    do: CallbackCommandContract.cancel_job_request(bundle.attempt.expected_job_id)

  defp rebuild_request(_bundle), do: {:error, :callback_command_stage_not_processable}

  defp exact_persisted_contract(bundle, request) do
    checks = [
      same_id?(bundle.command.id, bundle.attempt.command_id),
      bundle.command.command_type == bundle.attempt.command_type,
      bundle.command.agent_id == bundle.attempt.dispatch_agent_id,
      bundle.command.partition_id == bundle.attempt.dispatch_partition_id,
      value(bundle.grant, :dispatch_agent_id) == bundle.attempt.dispatch_agent_id,
      value(bundle.grant, :dispatch_partition_id) == bundle.attempt.dispatch_partition_id,
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
    cleanup_only = cleanup_only?(bundle, opts)

    cond do
      cleanup_only ->
        case process_cleanup_only_success(
               bundle,
               request,
               lease_token,
               result_digest,
               now,
               opts,
               true
             ) do
          {:ok, _next, _outcome} = success -> success
          {:error, reason} -> fail_closed(bundle, lease_token, result_digest, reason, now, opts)
        end

      successful_command?(bundle.command) ->
        case process_success(bundle, request, lease_token, result_digest, now, opts) do
          {:ok, _next, _outcome} = success -> success
          {:error, reason} -> fail_closed(bundle, lease_token, result_digest, reason, now, opts)
        end

      true ->
        process_command_failure(bundle, lease_token, result_digest, now, opts)
    end
  end

  defp cleanup_only?(bundle, opts) do
    value(value(bundle, :attempt) || %{}, :cleanup_only) == true or
      Keyword.get(opts, :cleanup_only, false)
  end

  defp process_cleanup_only_success(
         %{attempt: %Attempt{stage: stage}} = bundle,
         _request,
         token,
         digest,
         now,
         opts,
         true
       )
       when stage in [:create_credential, :fetch_credential] do
    expected = credential_provenance_request(bundle)

    with :ok <- validate_agent_credential_cleanup_result(bundle),
         {:ok, verified} <- verified_credentials(bundle, expected, opts) do
      case verified do
        %{complete?: true, credentials: [credential]} ->
          contain_verified_cleanup(
            bundle,
            %{credential_id: credential["id"]},
            token,
            digest,
            :credential_cleanup_contained,
            now,
            opts
          )

        %{complete?: true, credentials: []} ->
          schedule_cleanup_credential_lookup(bundle, token, digest, now, opts)

        %{complete?: false} ->
          {:error, :callback_credential_cleanup_lookup_incomplete}

        %{credentials: credentials} when length(credentials) > 1 ->
          {:error, :callback_credential_cleanup_ambiguous}
      end
    end
  end

  defp process_cleanup_only_success(
         %{attempt: %Attempt{stage: :launch_job}} = bundle,
         _request,
         token,
         digest,
         now,
         opts,
         true
       ) do
    case directly_verified_launch_candidate(bundle, opts) do
      {:ok, candidate} ->
        contain_verified_cleanup(
          bundle,
          %{
            credential_id: bundle.attempt.expected_credential_id,
            job_id: candidate.job_id
          },
          token,
          digest,
          :launch_cleanup_contained,
          now,
          opts
        )

      {:error, _reason} ->
        reconcile_cleanup_launch_candidates(bundle, token, digest, now, opts)
    end
  end

  defp process_cleanup_only_success(
         %{attempt: %Attempt{stage: :list_recent_jobs}} = bundle,
         request,
         token,
         digest,
         now,
         opts,
         true
       ) do
    with {:ok, verified} <- verified_recent_jobs(bundle, request, opts),
         {:ok, candidates} <- verified_reconciled_job_candidates(bundle, verified.jobs) do
      contain_cleanup_candidates(bundle, candidates, verified.complete?, token, digest, now, opts)
    end
  end

  defp process_cleanup_only_success(
         %{attempt: %Attempt{stage: :fetch_job, purpose: :accepted_job_proof}} = bundle,
         _request,
         token,
         digest,
         now,
         opts,
         true
       ) do
    with {:ok, job} <- verified_job(bundle, bundle.attempt.expected_job_id, opts),
         {:ok, snapshot} <-
           ExecutionLifecycle.accepted_job_snapshot(
             bundle.execution,
             bundle.controller.id,
             job,
             expected_ephemeral_credential_id: bundle.attempt.expected_credential_id
           ) do
      contain_verified_cleanup(
        bundle,
        %{
          credential_id: bundle.attempt.expected_credential_id,
          job_id: snapshot["awx_job_id"]
        },
        token,
        digest,
        :accepted_job_cleanup_contained,
        now,
        opts
      )
    end
  end

  # Once the preflight TTL closes, a job that was already dispatched must be
  # contained rather than activated. The independent controller lookup below
  # discovers its exact durable identity before any cancellation is scheduled.
  defp process_cleanup_only_success(
         %{attempt: %Attempt{stage: stage}} = bundle,
         _request,
         token,
         digest,
         now,
         opts,
         true
       )
       when stage in [:fetch_job, :fetch_host_summaries] do
    reconcile_cleanup_launch_candidates(bundle, token, digest, now, opts)
  end

  defp process_cleanup_only_success(
         %{attempt: %Attempt{stage: :cancel_job}} = bundle,
         _request,
         token,
         digest,
         now,
         opts,
         true
       ) do
    case verified_job(bundle, bundle.attempt.expected_job_id, opts) do
      {:ok, job} ->
        case SecureExecutionLifecycle.job_state(job) do
          {:ok, :active} -> retry_unconfirmed_cancel(bundle, token, digest, now, opts)
          {:ok, _terminal} -> advance_verified_cancel_queue(bundle, token, digest, now, opts)
          {:error, _reason} -> retry_unconfirmed_cancel(bundle, token, digest, now, opts)
        end

      {:error, _reason} ->
        retry_unconfirmed_cancel(bundle, token, digest, now, opts)
    end
  end

  defp process_cleanup_only_success(bundle, request, token, digest, now, opts, true) do
    case bundle.attempt.stage do
      :delete_credential ->
        process_success(
          bundle,
          request,
          token,
          digest,
          now,
          Keyword.put(opts, :cleanup_only, true)
        )

      _stage ->
        {:error, :callback_deadline_cleanup_only}
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
    expected = credential_provenance_request(bundle)

    with {:ok, credential_id} <- exact_create_result(bundle),
         {:ok, credential} <- verified_credential(bundle, credential_id, expected, opts) do
      bind_verified_credential(
        bundle,
        credential["id"],
        token,
        digest,
        :credential_directly_verified,
        now,
        opts
      )
    else
      {:error, _reason} -> reconcile_untrusted_credential_result(bundle, token, digest, now)
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
         {:ok, job} <- verified_job(bundle, job_id, opts),
         {:ok, snapshot} <-
           ExecutionLifecycle.accepted_job_snapshot(
             bundle.execution,
             bundle.controller.id,
             job,
             expected_ephemeral_credential_id: bundle.attempt.expected_credential_id
           ),
         {:ok, state} <- SecureExecutionLifecycle.job_state(job) do
      reconcile_verified_candidate(
        bundle,
        %{job: job, job_id: job_id, snapshot: snapshot, state: state},
        token,
        digest,
        now,
        opts
      )
    else
      {:error, _reason} -> reconcile_untrusted_launch_result(bundle, token, digest, now)
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
    expected = credential_provenance_request(bundle)

    with {:ok, _agent_result} <- exact_credential_lookup_result(bundle),
         {:ok, verified} <- verified_credentials(bundle, expected, opts) do
      case verified do
        %{complete?: true, credentials: [credential]} ->
          bind_verified_credential(
            bundle,
            credential["id"],
            token,
            digest,
            :credential_reconciled,
            now,
            opts
          )

        %{complete?: true, credentials: []} ->
          schedule_credential_lookup_poll(bundle, token, digest, now)

        %{complete?: false} ->
          {:error, :callback_credential_lookup_incomplete}

        %{credentials: credentials} when length(credentials) > 1 ->
          {:error, :callback_credential_lookup_ambiguous}
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
    with {:ok, job} <- verified_fetch_job(bundle, opts),
         :ok <- active_job(job),
         {:ok, accepted} <-
           ExecutionLifecycle.accepted_job_snapshot(bundle.execution, bundle.controller.id, job,
             expected_ephemeral_credential_id: bundle.attempt.expected_credential_id
           ),
         {:ok, execution} <-
           ExecutionLifecycle.bind_accepted_job(
             bundle.execution,
             bundle.controller.id,
             job,
             execution_lifecycle_opts(opts,
               expected_ephemeral_credential_id: bundle.attempt.expected_credential_id,
               targets: bundle.targets,
               mutating?: bundle.operation.mutating
             )
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
    with {:ok, job} <- verified_fetch_job(bundle, opts) do
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
    if bundle.attempt.cleanup_only == true or Keyword.get(opts, :cleanup_only, false) do
      {:error, :callback_deadline_cleanup_only}
    else
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
  end

  defp process_success(
         %{attempt: %Attempt{stage: :fetch_job, purpose: :terminal_poll}} = bundle,
         _request,
         token,
         digest,
         now,
         opts
       ) do
    with {:ok, job} <- verified_fetch_job(bundle, opts),
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
    with {:ok, _agent_result} <- exact_recent_jobs_result(bundle, request),
         {:ok, verified} <- verified_recent_jobs(bundle, request, opts),
         {:ok, candidates} <- verified_reconciled_job_candidates(bundle, verified.jobs) do
      cond do
        verified.complete? and candidates == [] ->
          schedule_recent_jobs_poll(bundle, request, token, digest, now, opts)

        verified.complete? and length(candidates) == 1 ->
          reconcile_verified_candidate(bundle, hd(candidates), token, digest, now, opts)

        not verified.complete? and candidates == [] ->
          schedule_recent_jobs_poll(bundle, request, token, digest, now, opts)

        true ->
          reason =
            if verified.complete?,
              do: :callback_launch_reconciliation_ambiguous,
              else: :callback_recent_jobs_incomplete

          contain_verified_candidates(bundle, candidates, token, digest, reason, now, opts)
      end
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
    with :ok <- exact_cancel_result(bundle) do
      case verified_job(bundle, bundle.attempt.expected_job_id, opts) do
        {:ok, job} ->
          case SecureExecutionLifecycle.job_state(job) do
            {:ok, :active} ->
              retry_unconfirmed_cancel(bundle, token, digest, now, opts)

            {:ok, _terminal} ->
              advance_verified_cancel_queue(bundle, token, digest, now, opts)

            {:error, _reason} ->
              retry_unconfirmed_cancel(bundle, token, digest, now, opts)
          end

        {:error, _reason} ->
          retry_unconfirmed_cancel(bundle, token, digest, now, opts)
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

  defp schedule_recent_jobs_poll(bundle, request, token, digest, now, opts) do
    next_at = DateTime.add(now, @poll_seconds, :second)

    with :ok <- before_deadline(bundle.attempt, next_at),
         {:ok, next_attrs} <-
           next_attempt_attrs(bundle, request, now,
             stage: :list_recent_jobs,
             purpose: :launch_reconciliation,
             command_type: "awx.list_recent_jobs",
             expected_credential_id: value(bundle.grant, :ephemeral_credential_id),
             reconcile_after: bundle.attempt.reconcile_after,
             next_attempt_at: next_at,
             attempt_store: callback_attempt_store(opts)
           ),
         {:ok, next} <-
           complete_with_next(
             bundle.attempt,
             token,
             digest,
             :launch_candidate_not_visible,
             next_attrs,
             now,
             opts
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
       when stage in [
              :fetch_credential,
              :fetch_job,
              :list_recent_jobs,
              :fetch_host_summaries,
              :cancel_job
            ] do
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
             candidate_job_ids: bundle.attempt.candidate_job_ids,
             next_attempt_at: next_at
           ) do
      {:ok, attrs, :read_only_transport_retry}
    end
  end

  defp reconciliation_attempt_attrs(_bundle, _now),
    do: {:error, :callback_command_not_reconcilable}

  # Transport ambiguity after preflight expiry is never allowed to restart the
  # ordinary create/launch chain. It is converted into a fresh-deadline,
  # cleanup-only lookup that can discover and remove an orphaned credential or
  # job without issuing either privileged mutation again.
  defp cleanup_reconciliation_attempt_attrs(
         %{attempt: %Attempt{stage: stage}} = bundle,
         now,
         opts
       )
       when stage in [:create_credential, :fetch_credential] do
    with {:ok, request} <-
           CallbackCommandContract.credential_lookup_request(
             bundle.execution,
             bundle.grant.awx_scope_snapshot
           ),
         {:ok, attrs} <-
           cleanup_attempt_attrs(
             bundle,
             request,
             now,
             [
               stage: :fetch_credential,
               purpose: :credential_reconciliation,
               command_type: "awx.fetch_callback_credential"
             ],
             opts
           ) do
      {:ok, attrs, :credential_cleanup_transport_reconciliation}
    end
  end

  defp cleanup_reconciliation_attempt_attrs(
         %{attempt: %Attempt{stage: :cancel_job}} = bundle,
         now,
         opts
       ) do
    with {:ok, request} <-
           CallbackCommandContract.cancel_job_request(bundle.attempt.expected_job_id),
         {:ok, attrs} <-
           cleanup_attempt_attrs(
             bundle,
             request,
             now,
             [
               stage: :cancel_job,
               purpose: :terminal_cleanup,
               command_type: "awx.cancel_job",
               expected_credential_id: cleanup_credential_id(bundle),
               expected_job_id: bundle.attempt.expected_job_id,
               candidate_job_ids: bundle.attempt.candidate_job_ids
             ],
             opts
           ) do
      {:ok, attrs, :cancel_cleanup_transport_reconciliation}
    end
  end

  defp cleanup_reconciliation_attempt_attrs(bundle, now, opts) do
    reconcile_after = cleanup_reconcile_after(bundle, now)

    with {:ok, request} <-
           CallbackCommandContract.recent_jobs_request(bundle.execution, reconcile_after),
         {:ok, attrs} <-
           cleanup_attempt_attrs(
             bundle,
             request,
             now,
             [
               stage: :list_recent_jobs,
               purpose: :launch_reconciliation,
               command_type: "awx.list_recent_jobs",
               expected_credential_id: cleanup_credential_id(bundle),
               reconcile_after: reconcile_after
             ],
             opts
           ) do
      {:ok, attrs, :launch_cleanup_transport_reconciliation}
    end
  end

  defp cleanup_reconcile_after(bundle, now) do
    bundle.attempt.reconcile_after || bundle.attempt.dispatched_at || bundle.attempt.inserted_at ||
      DateTime.add(now, -60, :second)
  end

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
             ~w(
               verb ok template_id inventory_id created_by_id created_after page_size
               max_candidates count complete jobs
             )
           ),
         true <- payload["verb"] == bundle.attempt.command_type,
         true <- payload["ok"] == true,
         true <- payload["template_id"] == value(request, :template_id),
         true <- payload["inventory_id"] == value(request, :inventory_id),
         true <- payload["created_by_id"] == value(request, :created_by_id),
         true <- payload["created_after"] == value(request, :created_after),
         true <- payload["page_size"] == value(request, :page_size),
         true <- payload["max_candidates"] == @max_recent_candidates,
         count when is_integer(count) and count in 0..@max_recent_candidates <- payload["count"],
         true <- payload["complete"] == true,
         jobs when is_list(jobs) and length(jobs) == count <- payload["jobs"] do
      {:ok, %{jobs: jobs, count: count, complete?: true}}
    else
      _ -> {:error, :callback_recent_jobs_result_mismatch}
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
      _ -> {:error, :callback_cancel_result_mismatch}
    end
  end

  defp verified_recent_jobs(bundle, request, opts) do
    verifier = Keyword.get(opts, :controller_provenance, ControllerProvenance)
    verifier_opts = controller_provenance_opts(bundle, opts)

    result =
      cond do
        is_function(verifier, 3) ->
          verifier.(bundle.controller, request, verifier_opts)

        is_atom(verifier) ->
          verifier.list_recent_jobs(bundle.controller, request, verifier_opts)

        true ->
          {:error, :controller_provenance_unavailable}
      end

    case result do
      {:ok, %{jobs: jobs, complete?: complete?}}
      when is_list(jobs) and is_boolean(complete?) ->
        {:ok, %{jobs: jobs, complete?: complete?}}

      {:error, _reason} = error ->
        error

      _ ->
        {:error, :controller_provenance_unavailable}
    end
  end

  defp credential_provenance_request(bundle) do
    %{
      credential_name: "sr-callback-#{bundle.execution.id}",
      credential_type_id: value(bundle.grant.awx_scope_snapshot, :callback_credential_type_id),
      organization_id:
        value(bundle.grant.awx_scope_snapshot, :callback_credential_organization_id)
    }
  end

  defp verified_credential(bundle, credential_id, expected, opts) do
    verifier =
      Keyword.get(opts, :controller_credential_provenance, ControllerProvenance)

    verifier_opts = controller_provenance_opts(bundle, opts)

    result =
      cond do
        is_function(verifier, 4) ->
          verifier.(bundle.controller, credential_id, expected, verifier_opts)

        is_atom(verifier) ->
          verifier.verify_callback_credential(
            bundle.controller,
            credential_id,
            expected,
            verifier_opts
          )

        true ->
          {:error, :controller_credential_provenance_unavailable}
      end

    case result do
      {:ok, %{"id" => ^credential_id} = credential} -> {:ok, credential}
      {:ok, _credential} -> {:error, :controller_credential_id_mismatch}
      {:error, _reason} = error -> error
      _ -> {:error, :controller_credential_provenance_unavailable}
    end
  end

  defp verified_credentials(bundle, expected, opts) do
    verifier = Keyword.get(opts, :controller_credential_lookup, ControllerProvenance)
    verifier_opts = controller_provenance_opts(bundle, opts)

    result =
      cond do
        is_function(verifier, 3) ->
          verifier.(bundle.controller, expected, verifier_opts)

        is_atom(verifier) ->
          verifier.find_callback_credentials(bundle.controller, expected, verifier_opts)

        true ->
          {:error, :controller_credential_provenance_unavailable}
      end

    case result do
      {:ok, %{credentials: credentials, complete?: complete?}}
      when is_list(credentials) and is_boolean(complete?) ->
        {:ok, %{credentials: credentials, complete?: complete?}}

      {:error, _reason} = error ->
        error

      _ ->
        {:error, :controller_credential_provenance_unavailable}
    end
  end

  defp bind_verified_credential(bundle, credential_id, token, digest, outcome, now, opts) do
    with {:ok, _bound} <-
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
           complete_with_next(bundle.attempt, token, digest, outcome, next_attrs, now) do
      {:ok, next, outcome}
    end
  end

  defp reconcile_untrusted_credential_result(bundle, token, digest, now) do
    with {:ok, next_attrs, _outcome} <- reconciliation_attempt_attrs(bundle, now),
         {:ok, next} <-
           ambiguous_with_next(
             bundle.attempt,
             token,
             digest,
             :credential_result_untrusted,
             next_attrs,
             now
           ) do
      {:ok, next, :credential_result_untrusted}
    end
  end

  defp reconcile_untrusted_launch_result(bundle, token, digest, now) do
    with {:ok, next_attrs, _outcome} <- reconciliation_attempt_attrs(bundle, now),
         {:ok, next} <-
           ambiguous_with_next(
             bundle.attempt,
             token,
             digest,
             :launch_result_untrusted,
             next_attrs,
             now
           ) do
      {:ok, next, :launch_result_untrusted}
    end
  end

  defp verified_fetch_job(bundle, opts) do
    with {:ok, _agent_job} <- exact_fetch_job_result(bundle) do
      verified_job(bundle, bundle.attempt.expected_job_id, opts)
    end
  end

  defp verified_job(bundle, job_id, opts) do
    verifier = Keyword.get(opts, :controller_provenance, ControllerProvenance)
    verifier_opts = controller_provenance_opts(bundle, opts)

    result =
      cond do
        is_function(verifier, 3) ->
          verifier.(bundle.controller, job_id, verifier_opts)

        is_atom(verifier) ->
          verifier.verify_job(bundle.controller, job_id, verifier_opts)

        true ->
          {:error, :controller_provenance_unavailable}
      end

    case result do
      {:ok, job} when is_map(job) -> {:ok, job}
      {:error, _reason} = error -> error
      _ -> {:error, :controller_provenance_unavailable}
    end
  end

  # An agent result is only a wake-up signal in cleanup-only mode. In
  # particular, a credential ID returned by the assigned agent must never
  # select the object that core deletes. The exact selector comes exclusively
  # from `verified_credentials/3` over the independent controller path.
  defp validate_agent_credential_cleanup_result(%{
         attempt: %Attempt{stage: stage},
         command: %AgentCommand{}
       })
       when stage in [:create_credential, :fetch_credential], do: :ok

  defp validate_agent_credential_cleanup_result(_bundle),
    do: {:error, :callback_credential_cleanup_stage_mismatch}

  defp directly_verified_launch_candidate(bundle, opts) do
    with {:ok, job_id} <- exact_launch_result(bundle),
         {:ok, job} <- verified_job(bundle, job_id, opts),
         {:ok, snapshot} <-
           ExecutionLifecycle.accepted_job_snapshot(
             bundle.execution,
             bundle.controller.id,
             job,
             expected_ephemeral_credential_id: bundle.attempt.expected_credential_id
           ),
         {:ok, state} <- SecureExecutionLifecycle.job_state(job) do
      {:ok, %{job: job, job_id: job_id, snapshot: snapshot, state: state}}
    end
  end

  defp reconcile_cleanup_launch_candidates(bundle, token, digest, now, opts) do
    reconcile_after =
      bundle.attempt.reconcile_after || bundle.attempt.dispatched_at || bundle.attempt.inserted_at ||
        DateTime.add(now, -60, :second)

    with {:ok, request} <-
           CallbackCommandContract.recent_jobs_request(bundle.execution, reconcile_after) do
      case verified_recent_jobs(bundle, request, opts) do
        {:ok, verified} ->
          with {:ok, candidates} <-
                 verified_reconciled_job_candidates(bundle, verified.jobs) do
            contain_cleanup_candidates(
              bundle,
              candidates,
              verified.complete?,
              token,
              digest,
              now,
              opts
            )
          end

        {:error, _reason} ->
          schedule_cleanup_recent_jobs(
            bundle,
            request,
            reconcile_after,
            token,
            digest,
            now,
            opts
          )
      end
    end
  end

  defp schedule_cleanup_credential_lookup(bundle, token, digest, now, opts) do
    with {:ok, request} <-
           CallbackCommandContract.credential_lookup_request(
             bundle.execution,
             bundle.grant.awx_scope_snapshot
           ),
         {:ok, next_attrs} <-
           cleanup_attempt_attrs(
             bundle,
             request,
             now,
             [
               stage: :fetch_credential,
               purpose: :credential_reconciliation,
               command_type: "awx.fetch_callback_credential"
             ],
             opts
           ),
         {:ok, next} <-
           complete_with_next(
             bundle.attempt,
             token,
             digest,
             :credential_cleanup_lookup_scheduled,
             next_attrs,
             now,
             opts
           ) do
      {:ok, next, :credential_cleanup_lookup_scheduled}
    end
  end

  defp schedule_cleanup_recent_jobs(bundle, request, reconcile_after, token, digest, now, opts) do
    with {:ok, next_attrs} <-
           cleanup_attempt_attrs(
             bundle,
             request,
             now,
             [
               stage: :list_recent_jobs,
               purpose: :launch_reconciliation,
               command_type: "awx.list_recent_jobs",
               expected_credential_id: cleanup_credential_id(bundle),
               reconcile_after: reconcile_after
             ],
             opts
           ),
         {:ok, next} <-
           complete_with_next(
             bundle.attempt,
             token,
             digest,
             :launch_cleanup_lookup_scheduled,
             next_attrs,
             now,
             opts
           ) do
      {:ok, next, :launch_cleanup_lookup_scheduled}
    end
  end

  defp contain_cleanup_candidates(bundle, [], true, token, digest, now, opts) do
    case cleanup_credential_id(bundle) do
      credential_id when is_integer(credential_id) and credential_id > 0 ->
        contain_verified_cleanup(
          bundle,
          %{credential_id: credential_id},
          token,
          digest,
          :launch_cleanup_no_job_found,
          now,
          opts
        )

      _missing ->
        {:error, :callback_cleanup_credential_identity_missing}
    end
  end

  defp contain_cleanup_candidates(bundle, [], false, token, digest, now, opts) do
    reconcile_after =
      bundle.attempt.reconcile_after || bundle.attempt.dispatched_at || bundle.attempt.inserted_at ||
        DateTime.add(now, -60, :second)

    with {:ok, request} <-
           CallbackCommandContract.recent_jobs_request(bundle.execution, reconcile_after) do
      schedule_cleanup_recent_jobs(
        bundle,
        request,
        reconcile_after,
        token,
        digest,
        now,
        opts
      )
    end
  end

  defp contain_cleanup_candidates(bundle, candidates, _complete?, token, digest, now, opts)
       when is_list(candidates) do
    active =
      candidates
      |> Enum.filter(&(&1.state == :active))
      |> Enum.sort_by(& &1.job_id)

    primary = List.first(active) || List.first(candidates)

    remaining_active_ids =
      active
      |> Enum.reject(&(&1.job_id == primary.job_id))
      |> Enum.map(& &1.job_id)
      |> Enum.uniq()
      |> Enum.sort()

    binding = %{
      credential_id: cleanup_credential_id(bundle),
      job_id: primary.job_id
    }

    with {:ok, _grant} <- revoke_verified_cleanup(bundle, binding, opts),
         {:ok, next_attrs} <-
           cleanup_candidate_cancel_attrs(bundle, remaining_active_ids, now, opts),
         {:ok, next} <-
           complete_cleanup_with_optional_next(
             bundle,
             token,
             digest,
             :verified_launch_cleanup_contained,
             next_attrs,
             now,
             opts
           ) do
      {:ok, next, :verified_launch_cleanup_contained}
    end
  end

  defp contain_verified_cleanup(bundle, binding, token, digest, outcome, now, opts) do
    with {:ok, _grant} <- revoke_verified_cleanup(bundle, binding, opts),
         {:ok, _attempt} <-
           complete_without_next(bundle.attempt, token, digest, outcome, now, opts) do
      {:ok, nil, outcome}
    end
  end

  defp revoke_verified_cleanup(bundle, binding, opts) do
    lifecycle = lifecycle(opts)

    if is_atom(lifecycle) and Code.ensure_loaded?(lifecycle) and
         function_exported?(lifecycle, :revoke_verified_cleanup, 4) do
      lifecycle.revoke_verified_cleanup(
        bundle.attempt.grant_id,
        binding,
        :callback_deadline_cleanup_only,
        lifecycle_opts!(opts)
      )
    else
      {:error, :verified_cleanup_binding_unavailable}
    end
  end

  defp cleanup_candidate_cancel_attrs(_bundle, [], _now, _opts), do: {:ok, nil}

  defp cleanup_candidate_cancel_attrs(bundle, [job_id | remaining], now, opts) do
    with {:ok, request} <- CallbackCommandContract.cancel_job_request(job_id) do
      cleanup_attempt_attrs(
        bundle,
        request,
        now,
        [
          stage: :cancel_job,
          purpose: :terminal_cleanup,
          command_type: "awx.cancel_job",
          expected_credential_id: cleanup_credential_id(bundle),
          expected_job_id: job_id,
          candidate_job_ids: remaining
        ],
        opts
      )
    end
  end

  defp complete_cleanup_with_optional_next(bundle, token, digest, outcome, nil, now, opts) do
    with {:ok, _attempt} <-
           complete_without_next(bundle.attempt, token, digest, outcome, now, opts) do
      {:ok, nil}
    end
  end

  defp complete_cleanup_with_optional_next(bundle, token, digest, outcome, next_attrs, now, opts) do
    complete_with_next(bundle.attempt, token, digest, outcome, next_attrs, now, opts)
  end

  # Cleanup-only attempts deliberately receive a fresh, short cleanup deadline.
  # Building them cannot consult the elapsed launch/create deadline, otherwise
  # recovery would lose the only path that can discover and remove an orphan.
  defp cleanup_attempt_attrs(bundle, request, now, attempt_opts, opts) do
    deadline_at = Keyword.get(attempt_opts, :deadline_at, DateTime.add(now, 60, :second))
    next_attempt_at = Keyword.get(attempt_opts, :next_attempt_at, now)

    number_opts =
      Keyword.put(attempt_opts, :attempt_store, callback_attempt_store(opts))

    CallbackCommandContract.build_attempt(
      %{
        grant_id: bundle.attempt.grant_id,
        operation_id: bundle.attempt.operation_id,
        execution_id: bundle.attempt.execution_id,
        controller_id: bundle.attempt.controller_id,
        dispatch_agent_id: bundle.attempt.dispatch_agent_id,
        dispatch_partition_id: bundle.attempt.dispatch_partition_id
      },
      bundle.execution,
      request,
      stage: Keyword.fetch!(attempt_opts, :stage),
      purpose: Keyword.fetch!(attempt_opts, :purpose),
      command_type: Keyword.fetch!(attempt_opts, :command_type),
      attempt: next_attempt_number(bundle.attempt, number_opts),
      expected_credential_id: Keyword.get(attempt_opts, :expected_credential_id),
      expected_job_id: Keyword.get(attempt_opts, :expected_job_id),
      reconcile_after: Keyword.get(attempt_opts, :reconcile_after),
      terminal_job_snapshot: Keyword.get(attempt_opts, :terminal_job_snapshot),
      candidate_job_ids: Keyword.get(attempt_opts, :candidate_job_ids, []),
      cleanup_only: true,
      deadline_at: deadline_at,
      next_attempt_at: next_attempt_at
    )
  end

  defp cleanup_credential_id(bundle) do
    bundle.attempt.expected_credential_id || value(bundle.grant, :ephemeral_credential_id)
  end

  defp advance_verified_cancel_queue(bundle, token, digest, now, opts) do
    case bundle.attempt.candidate_job_ids do
      [next_job_id | remaining] ->
        with {:ok, request} <- CallbackCommandContract.cancel_job_request(next_job_id),
             {:ok, next_attrs} <-
               next_attempt_attrs(bundle, request, now,
                 stage: :cancel_job,
                 purpose: :terminal_cleanup,
                 command_type: "awx.cancel_job",
                 expected_credential_id: bundle.attempt.expected_credential_id,
                 expected_job_id: next_job_id,
                 candidate_job_ids: remaining,
                 deadline_at: DateTime.add(now, 60, :second),
                 attempt_store: callback_attempt_store(opts)
               ),
             {:ok, next} <-
               complete_with_next(
                 bundle.attempt,
                 token,
                 digest,
                 :candidate_canceled,
                 next_attrs,
                 now,
                 opts
               ) do
          {:ok, next, :candidate_canceled}
        end

      [] ->
        with {:ok, _attempt} <-
               complete_without_next(
                 bundle.attempt,
                 token,
                 digest,
                 :cleanup_complete,
                 now,
                 opts
               ) do
          {:ok, nil, :cleanup_complete}
        end
    end
  end

  defp retry_unconfirmed_cancel(bundle, token, digest, now, opts) do
    next_at = DateTime.add(now, @poll_seconds, :second)

    with :ok <- before_deadline(bundle.attempt, next_at),
         {:ok, request} <-
           CallbackCommandContract.cancel_job_request(bundle.attempt.expected_job_id),
         {:ok, next_attrs} <-
           next_attempt_attrs(bundle, request, now,
             stage: :cancel_job,
             purpose: :terminal_cleanup,
             command_type: "awx.cancel_job",
             expected_credential_id: bundle.attempt.expected_credential_id,
             expected_job_id: bundle.attempt.expected_job_id,
             candidate_job_ids: bundle.attempt.candidate_job_ids,
             deadline_at: bundle.attempt.deadline_at,
             next_attempt_at: next_at,
             attempt_store: callback_attempt_store(opts)
           ),
         {:ok, next} <-
           complete_with_next(
             bundle.attempt,
             token,
             digest,
             :cancel_not_independently_confirmed,
             next_attrs,
             now,
             opts
           ) do
      {:ok, next, :cancel_not_independently_confirmed}
    end
  end

  defp verified_reconciled_job_candidates(bundle, jobs) do
    candidates =
      jobs
      |> Enum.reduce([], fn job, acc ->
        with {:ok, snapshot} <-
               ExecutionLifecycle.accepted_job_snapshot(
                 bundle.execution,
                 bundle.controller.id,
                 job,
                 expected_ephemeral_credential_id: value(bundle.grant, :ephemeral_credential_id)
               ),
             {:ok, state} <- SecureExecutionLifecycle.job_state(job) do
          [%{job: job, job_id: snapshot["awx_job_id"], snapshot: snapshot, state: state} | acc]
        else
          _ -> acc
        end
      end)
      |> Enum.sort_by(& &1.job_id)

    ids = Enum.map(candidates, & &1.job_id)

    if Enum.uniq(ids) == ids,
      do: {:ok, candidates},
      else: {:error, :controller_recent_jobs_duplicate_identity}
  end

  defp reconcile_verified_candidate(
         bundle,
         %{state: :active} = candidate,
         token,
         digest,
         now,
         opts
       ) do
    with {:ok, execution} <-
           ExecutionLifecycle.bind_accepted_job(
             bundle.execution,
             bundle.controller.id,
             candidate.job,
             execution_lifecycle_opts(opts,
               targets: bundle.targets,
               mutating?: bundle.operation.mutating,
               expected_ephemeral_credential_id: value(bundle.grant, :ephemeral_credential_id)
             )
           ),
         {:ok, binding} <- Lifecycle.job_binding_from_accepted(bundle.grant, candidate.snapshot),
         {:ok, _bound} <-
           lifecycle(opts).bind_job(bundle.attempt.grant_id, binding, lifecycle_opts!(opts)),
         bundle = %{bundle | execution: execution},
         {:ok, request} <-
           CallbackCommandContract.host_summaries_request(
             candidate.job_id,
             length(bundle.targets)
           ),
         {:ok, next_attrs} <-
           next_attempt_attrs(bundle, request, now,
             stage: :fetch_host_summaries,
             purpose: :host_scope_proof,
             command_type: "awx.fetch_job_host_summaries",
             expected_credential_id: value(bundle.grant, :ephemeral_credential_id),
             expected_job_id: candidate.job_id
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

  defp reconcile_verified_candidate(bundle, candidate, token, digest, now, opts) do
    with {:ok, execution} <-
           ExecutionLifecycle.bind_accepted_job(
             bundle.execution,
             bundle.controller.id,
             candidate.job,
             execution_lifecycle_opts(opts,
               targets: bundle.targets,
               mutating?: bundle.operation.mutating,
               expected_ephemeral_credential_id: value(bundle.grant, :ephemeral_credential_id)
             )
           ),
         {:ok, binding} <- Lifecycle.job_binding_from_accepted(bundle.grant, candidate.snapshot),
         {:ok, _bound} <-
           lifecycle(opts).bind_job(bundle.attempt.grant_id, binding, lifecycle_opts!(opts)),
         {:ok, _grant} <-
           lifecycle(opts).job_terminal(
             bundle.attempt.grant_id,
             normalized_job_status(candidate.job),
             lifecycle_opts!(opts)
           ),
         {:ok, _failed} <-
           SecureExecutionLifecycle.fail_closed(
             bundle.operation,
             execution,
             bundle.targets,
             :failed,
             :callback_reconciled_job_already_terminal,
             Keyword.put(secure_lifecycle_opts(opts), :cancel_required, false)
           ),
         {:ok, _attempt} <-
           complete_without_next(
             bundle.attempt,
             token,
             digest,
             :launch_reconciled_terminal,
             now
           ) do
      {:ok, nil, :launch_reconciled_terminal}
    end
  end

  defp contain_verified_candidates(bundle, candidates, token, digest, reason, now, opts) do
    active_job_ids =
      candidates
      |> Enum.filter(&(&1.state == :active))
      |> Enum.map(& &1.job_id)
      |> Enum.uniq()
      |> Enum.sort()

    with {:ok, next_attrs} <- candidate_cancel_attrs(bundle, active_job_ids, now, opts),
         {:ok, next} <-
           callback_transaction(opts, fn ->
             with {:ok, _attempt} <-
                    callback_attempt_store(opts).mark_ambiguous(
                      bundle.attempt,
                      %{
                        lease_token: token,
                        processed_at: now,
                        outcome_code: "verified_launch_candidates_contained",
                        last_error_code: error_code(reason),
                        result_digest: digest
                      },
                      actor: @actor
                    ),
                  {:ok, next} <- create_optional_callback_attempt(next_attrs, opts) do
               next
             else
               {:error, failure} -> callback_rollback(opts, failure)
             end
           end),
         revoke_result =
           lifecycle(opts).revoke(bundle.attempt.grant_id, reason, lifecycle_opts!(opts)),
         true <-
           callback_authority_removed?(revoke_result) || {:error, :callback_revocation_failed},
         {:ok, _failed} <-
           SecureExecutionLifecycle.fail_closed(
             bundle.operation,
             bundle.execution,
             bundle.targets,
             :dispatch_ambiguous,
             {reason, Enum.map(candidates, & &1.job_id)},
             Keyword.put(secure_lifecycle_opts(opts), :cancel_required, active_job_ids != [])
           ) do
      {:ok, next, :verified_launch_candidates_contained}
    else
      false -> {:error, :callback_revocation_failed}
      {:error, _reason} = error -> error
    end
  end

  defp candidate_cancel_attrs(_bundle, [], _now, _opts), do: {:ok, nil}

  defp candidate_cancel_attrs(bundle, [job_id | remaining], now, opts) do
    with {:ok, request} <- CallbackCommandContract.cancel_job_request(job_id) do
      next_attempt_attrs(bundle, request, now,
        stage: :cancel_job,
        purpose: :terminal_cleanup,
        command_type: "awx.cancel_job",
        expected_credential_id: value(bundle.grant, :ephemeral_credential_id),
        expected_job_id: job_id,
        candidate_job_ids: remaining,
        deadline_at: DateTime.add(now, 60, :second),
        attempt_store: callback_attempt_store(opts)
      )
    end
  end

  defp create_optional_callback_attempt(nil, _opts), do: {:ok, nil}

  defp create_optional_callback_attempt(attrs, opts),
    do: callback_attempt_store(opts).create_planned(attrs, actor: @actor)

  defp controller_provenance_opts(bundle, opts) do
    boundary = value(bundle, :controller_boundary) || %{}

    opts
    |> Keyword.get(:controller_provenance_opts, [])
    |> Keyword.put(
      :expected_controller_snapshot,
      value(boundary, :controller_security_snapshot)
    )
    |> Keyword.put(:expected_partition_id, value(boundary, :dispatch_partition_id))
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
          dispatch_agent_id: bundle.attempt.dispatch_agent_id,
          dispatch_partition_id: bundle.attempt.dispatch_partition_id
        },
        bundle.execution,
        request,
        stage: Keyword.fetch!(opts, :stage),
        purpose: Keyword.fetch!(opts, :purpose),
        command_type: Keyword.fetch!(opts, :command_type),
        attempt: next_attempt_number(bundle.attempt, opts),
        expected_credential_id: Keyword.get(opts, :expected_credential_id),
        expected_job_id: Keyword.get(opts, :expected_job_id),
        reconcile_after: Keyword.get(opts, :reconcile_after),
        terminal_job_snapshot: Keyword.get(opts, :terminal_job_snapshot),
        candidate_job_ids: Keyword.get(opts, :candidate_job_ids, []),
        cleanup_only: Keyword.get(opts, :cleanup_only, bundle.attempt.cleanup_only == true),
        deadline_at: Keyword.get(opts, :deadline_at, bundle.attempt.deadline_at),
        next_attempt_at: next_at
      )
    end
  end

  defp next_attempt_number(attempt, opts) do
    stage = Keyword.fetch!(opts, :stage)
    purpose = Keyword.fetch!(opts, :purpose)

    store = Keyword.get(opts, :attempt_store, Attempt)

    case store.list_for_grant(attempt.grant_id, actor: @actor) do
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
    complete_with_next(attempt, token, result_digest, outcome, next_attrs, now, [])
  end

  defp complete_with_next(attempt, token, result_digest, outcome, next_attrs, now, opts) do
    callback_transaction(opts, fn ->
      with {:ok, _completed} <-
             callback_attempt_store(opts).mark_succeeded(
               attempt,
               %{
                 lease_token: token,
                 processed_at: now,
                 outcome_code: Atom.to_string(outcome),
                 result_digest: result_digest
               },
               actor: @actor
             ),
           {:ok, next} <- callback_attempt_store(opts).create_planned(next_attrs, actor: @actor) do
        next
      else
        {:error, reason} -> callback_rollback(opts, reason)
      end
    end)
  end

  defp complete_without_next(attempt, token, result_digest, outcome, now) do
    complete_without_next(attempt, token, result_digest, outcome, now, [])
  end

  defp complete_without_next(attempt, token, result_digest, outcome, now, opts) do
    callback_attempt_store(opts).mark_succeeded(
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

  defp callback_attempt_store(opts), do: Keyword.get(opts, :attempt_store, Attempt)

  defp callback_transaction(opts, fun) do
    case Keyword.get(opts, :transaction) do
      callback when is_function(callback, 1) -> callback.(fun)
      _callback -> Repo.transaction(fun)
    end
  end

  defp callback_rollback(opts, reason) do
    case Keyword.get(opts, :rollback) do
      callback when is_function(callback, 1) -> callback.(reason)
      _callback -> Repo.rollback(reason)
    end
  end

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
        case Runtime.internal_opts() do
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
