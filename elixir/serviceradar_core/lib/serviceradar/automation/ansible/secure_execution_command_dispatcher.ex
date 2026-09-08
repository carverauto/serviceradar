defmodule ServiceRadar.Automation.Ansible.SecureExecutionCommandDispatcher do
  @moduledoc """
  Claims and dispatches one durable hardened non-callback AWX command.

  Every request is rebuilt from immutable server state. A preallocated command
  UUID closes the dispatch crash window; a persisted command is reconciled and
  never blindly retransmitted.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Automation.Ansible.AutomationExecution
  alias ServiceRadar.Automation.Ansible.AutomationExecutionTarget
  alias ServiceRadar.Automation.Ansible.AutomationOperation

  alias ServiceRadar.Automation.Ansible.AutomationSecureExecutionCommandAttempt,
    as: Attempt

  alias ServiceRadar.Automation.Ansible.AwxClient
  alias ServiceRadar.Automation.Ansible.AwxLaunchPreflightAttestation
  alias ServiceRadar.Automation.Ansible.Controller
  alias ServiceRadar.Automation.Ansible.SecureExecutionContinuationBoundary
  alias ServiceRadar.Automation.Ansible.SafeFailureEvidence
  alias ServiceRadar.Automation.Ansible.SecureExecutionAuthorityContraction
  alias ServiceRadar.Automation.Ansible.SecureExecutionCommandContract, as: Contract
  alias ServiceRadar.Automation.Ansible.SecureExecutionCurrentAuthority
  alias ServiceRadar.Edge.AgentCommand
  alias ServiceRadar.Edge.AgentCommandBus

  @actor SystemActor.system(:secure_execution_command_dispatcher)
  @lease_seconds 15

  @spec dispatch(Attempt.t(), keyword()) :: {:ok, atom()} | {:error, term()}
  def dispatch(attempt, opts \\ [])

  def dispatch(%Attempt{} = attempt, opts) do
    now = now(opts)

    with :ok <- before_deadline(attempt, now),
         {:ok, resources} <- load_resources(attempt, opts),
         :ok <- ensure_non_callback(resources.operation),
         :ok <- ensure_lifecycle_state(attempt, resources.operation, resources.execution),
         :ok <- verify_controller_boundary(attempt, resources, now, opts),
         {:ok, request} <- rebuild_request(attempt, resources),
         true <-
           Contract.request_matches?(attempt, request) ||
             {:error, :secure_execution_request_digest_mismatch},
         context = Contract.context(attempt, resources.execution),
         true <-
           Contract.context_matches?(attempt, resources.execution, context) ||
             {:error, :secure_execution_context_digest_mismatch},
         :ok <- authorize_current_attempt(attempt, resources, now, opts),
         {:ok, claimed, lease_token} <- claim(attempt, now, opts) do
      dispatch_claimed(
        claimed,
        lease_token,
        resources.execution,
        resources.controller,
        request,
        context,
        now,
        opts
      )
    else
      false ->
        {:error, :secure_execution_command_contract_mismatch}

      {:error, {:secure_execution_current_authority_denied, reason}} ->
        persist_authority_denial(attempt, reason, now, opts)

      {:error, _reason} = error ->
        error
    end
  rescue
    _ -> {:error, :secure_execution_command_dispatch_unavailable}
  catch
    _, _ -> {:error, :secure_execution_command_dispatch_unavailable}
  end

  def dispatch(_attempt, _opts), do: {:error, :invalid_secure_execution_command_attempt}

  @doc "Reauthorizes a known in-flight AWX child without redispatching its command."
  @spec reauthorize_continuation(Attempt.t(), keyword()) :: :ok | {:error, term()}
  def reauthorize_continuation(attempt, opts \\ [])

  def reauthorize_continuation(%Attempt{} = attempt, opts) when is_list(opts) do
    if continuation_authority_required?(attempt) do
      now = now(opts)

      with {:ok, resources} <- load_resources(attempt, opts),
           :ok <- ensure_non_callback(resources.operation),
           :ok <- verify_controller_boundary(attempt, resources, now, opts),
           :ok <- ensure_lifecycle_state(attempt, resources.operation, resources.execution),
           :ok <- authorize_current_attempt(attempt, resources, now, opts) do
        :ok
      else
        {:error, {:secure_execution_current_authority_denied, reason}} ->
          persist_authority_denial(attempt, reason, now, opts)

        {:error, _reason} = error ->
          error
      end
    else
      :ok
    end
  rescue
    _ -> {:error, :secure_execution_continuation_reauthorization_unavailable}
  catch
    _, _ -> {:error, :secure_execution_continuation_reauthorization_unavailable}
  end

  def reauthorize_continuation(_attempt, _opts),
    do: {:error, :invalid_secure_execution_command_attempt}

  defp load_resources(attempt, opts) do
    loader = Keyword.get(opts, :resource_loader, &load_persisted_resources/1)

    if is_function(loader, 1),
      do: loader.(attempt),
      else: {:error, :secure_execution_resource_loader_unavailable}
  end

  defp load_persisted_resources(attempt) do
    with {:ok, %AutomationOperation{} = operation} <-
           required(AutomationOperation.get_by_id(attempt.operation_id, actor: @actor)),
         {:ok, %AutomationExecution{} = execution} <-
           required(AutomationExecution.get_by_id(attempt.execution_id, actor: @actor)),
         {:ok, %Controller{} = controller} <-
           required(Controller.get_by_id(attempt.controller_id, actor: @actor)),
         {:ok, targets} <-
           AutomationExecutionTarget.list_for_execution(attempt.execution_id, actor: @actor),
         true <-
           controller.agent_id == attempt.dispatch_agent_id ||
             {:error, :secure_execution_controller_agent_mismatch},
         true <-
           (execution.operation_id == operation.id and execution.controller_id == controller.id) ||
             {:error, :secure_execution_resource_mismatch} do
      {:ok,
       %{operation: operation, execution: execution, controller: controller, targets: targets}}
    else
      false -> {:error, :secure_execution_resource_mismatch}
      {:error, _reason} = error -> error
    end
  end

  defp ensure_non_callback(%{callback_actions: []}), do: :ok
  defp ensure_non_callback(_operation), do: {:error, :callback_execution_isolated}

  # `:launch_job` is the only secure-dispatcher stage that can create an AWX
  # job. It must be backed by the matching immutable operation/execution
  # attestation and independently persisted evidence; a legacy metadata
  # snapshot is deliberately not an authority for a new launch.
  defp verify_controller_boundary(%Attempt{stage: :launch_job} = attempt, resources, now, opts) do
    with {:ok, attestation} <-
           AwxLaunchPreflightAttestation.verify_persisted(
             value(resources, :operation),
             value(resources, :execution),
             value(resources, :controller),
             now,
             preflight_verification_opts(opts)
           ) do
      AwxLaunchPreflightAttestation.verify_dispatch_principal(
        attestation,
        attempt.dispatch_agent_id,
        attempt.dispatch_partition_id
      )
    end
  end

  # Existing children retain their immutable boundary after the launch TTL.
  # This clause cannot dispatch a launch; that stage always uses the fresh
  # attestation verifier above.
  defp verify_controller_boundary(attempt, resources, now, opts) do
    SecureExecutionContinuationBoundary.verify(resources, attempt, now, opts)
  end

  defp preflight_verification_opts(opts) do
    case Keyword.fetch(opts, :preflight_evidence_reader) do
      {:ok, reader} -> [evidence_reader: reader]
      :error -> []
    end
  end

  defp ensure_lifecycle_state(
         %Attempt{stage: :launch_job, purpose: :accepted_job_proof},
         %{state: :dispatching},
         %{
           state: :dispatching
         }
       ),
       do: :ok

  defp ensure_lifecycle_state(
         %Attempt{stage: :list_recent_jobs, purpose: :launch_reconciliation},
         %{state: :dispatching},
         %{state: :dispatching}
       ),
       do: :ok

  defp ensure_lifecycle_state(
         %Attempt{stage: :fetch_job, purpose: :accepted_job_proof},
         %{state: :dispatching},
         %{
           state: :dispatching
         }
       ),
       do: :ok

  defp ensure_lifecycle_state(
         %Attempt{stage: :fetch_job, purpose: :scope_poll},
         %{state: :dispatching},
         %{
           state: :launching
         }
       ),
       do: :ok

  defp ensure_lifecycle_state(
         %Attempt{stage: :fetch_host_summaries, purpose: :host_scope_proof},
         %{state: :dispatching},
         %{state: :launching}
       ),
       do: :ok

  defp ensure_lifecycle_state(
         %Attempt{stage: :fetch_job, purpose: :terminal_poll},
         %{state: :running},
         %{state: :running}
       ),
       do: :ok

  defp ensure_lifecycle_state(
         %Attempt{stage: :fetch_host_summaries, purpose: :terminal_confirmation},
         %{state: :running},
         %{state: :running}
       ),
       do: :ok

  defp ensure_lifecycle_state(
         %Attempt{stage: :cancel_job, purpose: :terminal_cleanup},
         %{state: state},
         %{state: state}
       )
       when state in [:failed, :dispatch_ambiguous, :cancel_failed], do: :ok

  defp ensure_lifecycle_state(_attempt, _operation, _execution),
    do: {:error, :secure_execution_lifecycle_state_mismatch}

  defp authorize_current_attempt(attempt, resources, now, opts) do
    if current_authority_required?(attempt) do
      do_authorize_current_attempt(attempt, resources, now, opts)
    else
      :ok
    end
  end

  defp do_authorize_current_attempt(attempt, resources, now, opts) do
    authorizer =
      Keyword.get(opts, :current_authorizer, &SecureExecutionCurrentAuthority.authorize_attempt/4)

    context = Keyword.get(opts, :current_authority_context, [])

    result =
      cond do
        is_function(authorizer, 4) -> authorizer.(attempt, resources, now, context)
        is_function(authorizer, 3) -> authorizer.(resources, now, context)
        true -> {:error, :current_authority_required}
      end

    case result do
      :ok ->
        :ok

      {:ok, _authority} ->
        :ok

      {:error, reason} ->
        {:error, {:secure_execution_current_authority_denied, reason}}

      _ ->
        {:error, {:secure_execution_current_authority_denied, :current_authority_required}}
    end
  end

  defp current_authority_required?(%Attempt{stage: :launch_job}), do: true

  defp current_authority_required?(attempt), do: continuation_authority_required?(attempt)

  defp continuation_authority_required?(%Attempt{stage: :fetch_job, purpose: purpose})
       when purpose in [:accepted_job_proof, :scope_poll, :terminal_poll], do: true

  defp continuation_authority_required?(%Attempt{stage: :fetch_host_summaries, purpose: purpose})
       when purpose in [:host_scope_proof, :terminal_confirmation], do: true

  # Launch reconciliation and cancellation are safety/cleanup paths. They may
  # continue under the immutable contract so an unknown or unauthorized child
  # can be discovered and stopped; they cannot activate or enlarge authority.
  defp continuation_authority_required?(_attempt), do: false

  defp resources_for_denial(attempt, opts) do
    case load_resources(attempt, opts) do
      {:ok, resources} -> resources
      _ -> nil
    end
  end

  defp persist_authority_denial(attempt, reason, now, opts) do
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
         {:secure_execution_authority_denial_persistence_failed,
          SafeFailureEvidence.code(marker_reason)}}
    end
  end

  defp record_authority_denial(attempt, resources, reason, now, opts) when is_map(resources) do
    marker = Keyword.get(opts, :authority_denial_handler)

    marker =
      if is_function(marker, 4) do
        marker
      else
        fn denied_attempt, denied_resources, denied_reason, denied_at ->
          SecureExecutionAuthorityContraction.deny(
            denied_attempt,
            denied_resources,
            denied_reason,
            denied_at,
            opts
          )
        end
      end

    case marker.(attempt, resources, reason, now) do
      :ok -> :ok
      {:ok, _result} -> :ok
      {:error, _reason} = error -> error
      _ -> {:error, :secure_execution_authority_denial_handler_unavailable}
    end
  end

  defp record_authority_denial(_attempt, _resources, _reason, _now, _opts),
    do: {:error, :secure_execution_authority_denial_resources_unavailable}

  defp rebuild_request(%Attempt{stage: :launch_job}, resources),
    do: Contract.launch_request(resources.operation, resources.execution)

  defp rebuild_request(%Attempt{stage: :fetch_job} = attempt, _resources),
    do: Contract.fetch_job_request(attempt.expected_job_id)

  defp rebuild_request(%Attempt{stage: :fetch_host_summaries} = attempt, resources) do
    target_count = length(resources.targets)
    Contract.host_summaries_request(attempt.expected_job_id, target_count)
  end

  defp rebuild_request(%Attempt{stage: :list_recent_jobs} = attempt, resources),
    do: Contract.recent_jobs_request(resources.execution, attempt.reconcile_after)

  defp rebuild_request(%Attempt{stage: :cancel_job} = attempt, _resources),
    do: Contract.cancel_job_request(attempt.expected_job_id)

  defp rebuild_request(_attempt, _resources),
    do: {:error, :secure_execution_command_stage_not_dispatchable}

  defp claim(attempt, now, opts) do
    lease_token = Ecto.UUID.generate()
    lease_expires_at = DateTime.add(now, @lease_seconds, :second)
    claimer = Keyword.get(opts, :claim, &claim_persisted/4)

    case claimer.(attempt, lease_token, lease_expires_at, now) do
      {:ok, claimed} -> {:ok, claimed, lease_token}
      {:error, reason} -> {:error, {:secure_execution_command_claim_failed, reason}}
    end
  end

  defp claim_persisted(attempt, lease_token, lease_expires_at, now) do
    Attempt.claim_dispatch(
      attempt,
      %{lease_token: lease_token, lease_expires_at: lease_expires_at, now: now},
      actor: @actor
    )
  end

  defp dispatch_claimed(attempt, lease_token, execution, controller, request, context, now, opts) do
    dispatcher = Keyword.get(opts, :awx_dispatcher, &dispatch_awx/5)

    case dispatcher.(attempt, controller, request, context, opts) do
      {:ok, command} ->
        with :ok <- exact_command_id(command, attempt.command_id) do
          mark_dispatched_replay_safe(attempt, lease_token, now, opts)
        end

      {:error, reason} ->
        reconcile_dispatch_error(
          attempt,
          lease_token,
          execution,
          controller,
          request,
          context,
          reason,
          now,
          opts
        )
    end
  end

  defp dispatch_awx(%Attempt{stage: :launch_job} = attempt, controller, request, context, opts) do
    AwxClient.launch_job(controller, request.template_id, request.launch_opts,
      command_id: attempt.command_id,
      secure_execution_attempt: true,
      required_partition: attempt.dispatch_partition_id,
      source: :automation,
      context: context,
      command_bus: Keyword.get(opts, :command_bus, AgentCommandBus)
    )
  end

  defp dispatch_awx(%Attempt{stage: :fetch_job} = attempt, controller, request, context, opts) do
    AwxClient.fetch_job(controller, request.job_id,
      command_id: attempt.command_id,
      secure_execution_attempt: true,
      required_partition: attempt.dispatch_partition_id,
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
      secure_execution_attempt: true,
      required_partition: attempt.dispatch_partition_id,
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
      secure_execution_attempt: true,
      required_partition: attempt.dispatch_partition_id,
      source: :automation,
      context: context,
      command_bus: Keyword.get(opts, :command_bus, AgentCommandBus)
    )
  end

  defp dispatch_awx(%Attempt{stage: :cancel_job} = attempt, controller, request, context, opts) do
    AwxClient.cancel_job(controller, request.job_id,
      command_id: attempt.command_id,
      secure_execution_attempt: true,
      required_partition: attempt.dispatch_partition_id,
      source: :automation,
      context: context,
      command_bus: Keyword.get(opts, :command_bus, AgentCommandBus)
    )
  end

  defp dispatch_awx(_attempt, _controller, _request, _context, _opts),
    do: {:error, :secure_execution_command_stage_not_dispatchable}

  defp reconcile_dispatch_error(
         attempt,
         lease_token,
         execution,
         controller,
         request,
         context,
         reason,
         now,
         opts
       ) do
    case fetch_command(attempt.command_id, opts) do
      {:ok, %AgentCommand{} = command} ->
        if exact_persisted_command?(
             command,
             attempt,
             execution,
             controller,
             request,
             context
           ) do
          mark_dispatched_replay_safe(attempt, lease_token, now, opts)
        else
          {:error, :secure_execution_persisted_command_correlation_mismatch}
        end

      {:ok, nil} ->
        release_dispatch(attempt, lease_token, reason, now, opts)

      {:error, _fetch_reason} ->
        {:error, :secure_execution_dispatch_persistence_ambiguous}
    end
  end

  defp fetch_command(command_id, opts) do
    fetcher = Keyword.get(opts, :command_fetcher, &fetch_persisted_command/1)
    fetcher.(command_id)
  end

  defp fetch_persisted_command(command_id), do: AgentCommand.get_by_id(command_id, actor: @actor)

  defp mark_dispatched_replay_safe(attempt, lease_token, now, opts) do
    marker = Keyword.get(opts, :mark_dispatched, &mark_dispatched_persisted/3)

    case marker.(attempt, lease_token, now) do
      {:ok, _updated} ->
        {:ok, :dispatched}

      {:error, mark_reason} ->
        fetcher = Keyword.get(opts, :attempt_fetcher, &fetch_persisted_attempt/1)

        case fetcher.(attempt.id) do
          {:ok, %Attempt{command_id: command_id, state: state}}
          when state in [:processing, :succeeded, :failed, :ambiguous] ->
            if same_id?(command_id, attempt.command_id),
              do: {:ok, :result_already_processing},
              else: {:error, :secure_execution_attempt_correlation_mismatch}

          {:ok, _other} ->
            {:error, {:secure_execution_mark_dispatched_failed, mark_reason}}

          {:error, fetch_reason} ->
            {:error, {:secure_execution_mark_dispatched_state_unknown, mark_reason, fetch_reason}}
        end
    end
  end

  defp fetch_persisted_attempt(id), do: Attempt.get_by_id(id, actor: @actor)

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

    case releaser.(attempt, lease_token, DateTime.add(now, 1, :second), error_code(reason)) do
      {:ok, _updated} -> {:ok, :deferred}
      {:error, release_reason} -> {:error, {:secure_execution_release_failed, release_reason}}
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

  defp exact_persisted_command?(command, attempt, execution, controller, request, context) do
    same_id?(command.id, attempt.command_id) and
      command.command_type == attempt.command_type and
      command.agent_id == attempt.dispatch_agent_id and
      command.partition_id == attempt.dispatch_partition_id and
      Contract.context_matches?(attempt, execution, command.context || %{}) and
      command.context == context and
      Contract.persisted_payload_matches?(
        attempt,
        execution,
        controller,
        request,
        command.payload || %{}
      )
  end

  defp exact_command_id(%{id: command_id}, expected), do: exact_command_id(command_id, expected)

  defp exact_command_id(command_id, expected) when is_binary(command_id),
    do: if(same_id?(command_id, expected), do: :ok, else: {:error, :command_id_mismatch})

  defp exact_command_id(_command, _expected), do: {:error, :command_id_missing}

  defp before_deadline(attempt, now) do
    if DateTime.before?(now, attempt.deadline_at),
      do: :ok,
      else: {:error, :secure_execution_command_deadline_elapsed}
  end

  defp required({:ok, nil}), do: {:error, :secure_execution_resource_not_found}
  defp required({:ok, value}), do: {:ok, value}
  defp required({:error, reason}), do: {:error, reason}

  defp now(opts),
    do: opts |> Keyword.get(:now, DateTime.utc_now()) |> DateTime.truncate(:microsecond)

  defp same_id?(left, right), do: to_string(left) == to_string(right)

  defp error_code(reason), do: SafeFailureEvidence.code(reason)
  defp value(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp value(_map, _key), do: nil
end
