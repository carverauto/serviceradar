defmodule ServiceRadar.Automation.Ansible.CallbackLaunchOrchestrator do
  @moduledoc """
  Persists and dispatches the initial callback-credential command for one child.

  This module deliberately stops after dispatching
  `awx.create_callback_credential`. The result orchestrator owns credential
  binding, exact accepted-job/host-scope proof, activation, and immediate
  credential deletion. No AWX job is launched from this boundary.
  """

  alias ServiceRadar.Automation.Ansible.AwxLaunchPreflightAttestation
  alias ServiceRadar.Automation.Ansible.CallbackLaunchOrchestrator.AshActions
  alias ServiceRadar.Automation.Ansible.CallbackResponsePolicy
  alias ServiceRadar.Automation.CallbackGrants.ActionContract
  alias ServiceRadar.Automation.CallbackGrants.Authority
  alias ServiceRadar.Automation.CallbackGrants.Runtime
  alias ServiceRadar.Automation.CallbackGrants.RuntimeConfig
  alias ServiceRadar.Automation.LaunchEnvelopes
  alias ServiceRadar.Edge.AgentCommandBus

  @audience "serviceradar.awx.callback/v1"
  @principal_types [:human, :service_principal, "human", "service_principal"]

  @spec launch(map(), struct(), keyword()) :: {:ok, map()} | {:error, term()}
  def launch(plan, controller, opts \\ [])

  def launch(plan, controller, opts) when is_map(plan) and is_map(controller) and is_list(opts) do
    actions = Keyword.get(opts, :actions, AshActions)
    envelopes = Keyword.get(opts, :launch_envelopes, LaunchEnvelopes)
    now = now(opts)

    with {:ok, launch_contract} <- callback_contract(plan),
         {:ok, action_contract} <- ActionContract.fetch(launch_contract.action),
         :ok <- exact_action_contract(launch_contract, action_contract),
         :ok <- validate_initiating_authority(plan, action_contract),
         {:ok, response_policy} <- response_policy(plan, launch_contract, opts),
         {:ok, callback_origin} <- RuntimeConfig.configured_callback_origin(),
         {:ok, lifecycle_opts} <- lifecycle_opts(opts),
         {:ok, edge_principal} <- authenticated_edge_principal(controller, opts),
         :ok <- verify_live_preflight(plan, controller, edge_principal, now, opts),
         envelope_opts = envelope_opts(opts),
         {:ok, allocation} <- envelopes.allocate(envelope_opts),
         {:ok, grant_id} <- grant_id(opts),
         {:ok, callback} <-
           callback_context(
             plan,
             controller,
             launch_contract,
             action_contract,
             response_policy,
             callback_origin,
             lifecycle_opts,
             envelope_opts,
             allocation,
             grant_id,
             edge_principal
           ),
         callback_plan = callback_plan(plan, callback),
         {:ok, persisted} <- actions.persist_callback_plan(callback_plan, callback) do
      after_commit(actions, persisted, controller, callback_plan, callback)
    end
  rescue
    _ -> {:error, :callback_launch_unavailable}
  catch
    _, _ -> {:error, :callback_launch_unavailable}
  end

  def launch(_plan, _controller, _opts), do: {:error, :invalid_callback_launch_plan}

  # This boundary deliberately runs before a callback envelope or grant is
  # allocated. HardenedRunLauncher performs the same check for its normal
  # entrypoint, but CallbackLaunchOrchestrator is also callable by durable
  # recovery and must not become a bypass around the immutable preflight.
  defp verify_live_preflight(plan, controller, edge_principal, now, opts) do
    verification_opts =
      case Keyword.fetch(opts, :preflight_evidence_reader) do
        {:ok, reader} -> [evidence_reader: reader]
        :error -> []
      end

    with {:ok, snapshot} <-
           AwxLaunchPreflightAttestation.verify_persisted(
             value(plan, :operation),
             value(plan, :execution),
             controller,
             now,
             verification_opts
           ) do
      AwxLaunchPreflightAttestation.verify_dispatch_principal(
        snapshot,
        edge_principal.agent_id,
        edge_principal.partition_id
      )
    end
  end

  defp after_commit(actions, persisted, controller, plan, callback) do
    case actions.mark_dispatching(persisted) do
      :ok ->
        dispatch_credential(actions, persisted, controller, plan, callback)

      {:error, _reason} ->
        fail_after_commit(actions, persisted, callback, :dispatch_state_update_failed)
    end
  end

  defp dispatch_credential(actions, persisted, controller, _plan, callback) do
    case actions.dispatch_callback_credential(controller, persisted.callback.attempt) do
      {:ok, _command} ->
        {:ok,
         %{
           operation: persisted.operation,
           execution: persisted.execution,
           targets: persisted.targets,
           callback: %{
             grant_id: callback.grant_id,
             command_id: callback.command_id,
             state: :pending,
             dispatch: :accepted
           }
         }}

      {:error, _reason} ->
        fail_after_commit(actions, persisted, callback, :callback_credential_dispatch_failed)
    end
  end

  defp fail_after_commit(actions, persisted, callback, reason) do
    # Authority is removed before run state is marked failed. Cleanup is a
    # no-op here because this synchronous failure returned no credential ID.
    revoke_result =
      actions.revoke_callback_grant(callback.grant_id, reason, callback.lifecycle_opts)

    failure_code =
      if match?({:ok, _}, revoke_result),
        do: reason,
        else: :callback_grant_revocation_failed

    _ = actions.mark_callback_dispatch_failed(persisted, failure_code)
    {:error, {:dispatch_failed, failure_code}}
  end

  defp callback_contract(%{callback_contract: contract}) when is_map(contract),
    do: {:ok, contract}

  defp callback_contract(_plan), do: {:error, :callback_launch_contract_required}

  defp exact_action_contract(contract, action_contract) do
    if contract.action_version == action_contract.version,
      do: :ok,
      else: {:error, :callback_action_version_mismatch}
  end

  defp validate_initiating_authority(plan, action_contract) do
    operation = Map.get(plan, :operation, %{})
    principal_type = value(operation, :initiator_principal_type)
    principal_id = value(operation, :initiator_principal_id)
    owner_id = value(operation, :service_principal_owner_id)
    ceiling = value(operation, :authority_ceiling) || %{}
    permissions = MapSet.new(List.wrap(value(ceiling, :permissions)))
    required = MapSet.new(ActionContract.required_permissions(action_contract))

    cond do
      principal_type not in @principal_types ->
        {:error, :initiating_principal_required}

      not is_binary(principal_id) or principal_id == "" or
          String.starts_with?(principal_id, "system:") ->
        {:error, :system_actor_has_no_authority}

      principal_type in [:service_principal, "service_principal"] and
          (not is_binary(owner_id) or owner_id == "") ->
        {:error, :service_principal_owner_required}

      not MapSet.subset?(required, permissions) ->
        {:error, :issuance_permission_ceiling_exceeded}

      action_contract.action not in List.wrap(value(operation, :callback_actions)) ->
        {:error, :action_outside_issuance_ceiling}

      true ->
        :ok
    end
  end

  defp response_policy(plan, launch_contract, opts) do
    expected_targets = provider_targets(plan)
    approval = value(plan.operation, :approval_snapshot) || %{}

    provider_context = %{
      action: launch_contract.action,
      action_version: launch_contract.action_version,
      policy_version: launch_contract.policy_version,
      tenant_id: to_string(value(plan.operation, :tenant_id)),
      controller_id: plan.execution.controller_id,
      inventory_id: plan.execution.inventory_id,
      job_template_id: plan.execution.job_template_id,
      binding_id: value(approval, :binding_id),
      binding_version: value(approval, :binding_version),
      approval_id: value(approval, :approval_id),
      approval_expires_at: value(approval, :approval_expires_at),
      reviewed_by_principal_type: value(approval, :reviewed_by_principal_type),
      reviewed_by_principal_id: value(approval, :reviewed_by_principal_id),
      reviewed_at: value(approval, :reviewed_at),
      scm_revision: plan.execution.scm_revision,
      content_sha256: plan.execution.content_sha256,
      now: Keyword.get(opts, :now, DateTime.utc_now()),
      targets: expected_targets
    }

    with {:ok, policy} <-
           CallbackResponsePolicy.snapshot(provider_context,
             provider: Keyword.get(opts, :response_policy_provider)
           ) do
      {:ok,
       %{
         digest: policy.digest,
         snapshot: %{
           "manifest_sha256" => launch_contract.manifest_sha256,
           "phase" => launch_contract.phase,
           "operation" => launch_contract.operation,
           "state" => launch_contract.state,
           "targets" => policy.targets
         }
       }}
    end
  end

  defp provider_targets(plan) do
    Enum.map(plan.targets, fn target ->
      %{
        "inventory_hostname" => target.host_name,
        "inventory_address" => target.ansible_host,
        "target_identity" => %{
          "controller_id" => to_string(target.controller_id),
          "inventory_id" => target.inventory_id,
          "awx_host_id" => target.awx_host_id,
          "canonical_device_uid" => target.canonical_device_uid
        }
      }
    end)
  end

  defp lifecycle_opts(opts) do
    case Keyword.fetch(opts, :lifecycle_opts) do
      {:ok, lifecycle_opts} when is_list(lifecycle_opts) -> {:ok, lifecycle_opts}
      {:ok, _invalid} -> {:error, :callback_unavailable}
      :error -> Runtime.issuance_opts()
    end
  end

  defp envelope_opts(opts) do
    opts
    |> Keyword.get(:envelope_opts, [])
    |> Keyword.put_new(:now, Keyword.get(opts, :now, DateTime.utc_now()))
  end

  defp grant_id(opts) do
    id = Keyword.get_lazy(opts, :grant_id, &Ash.UUIDv7.generate/0)

    case Ash.Type.UUIDv7.cast_input(id, []) do
      {:ok, canonical} -> {:ok, canonical}
      :error -> {:error, :invalid_callback_grant_id}
    end
  end

  defp callback_context(
         plan,
         controller,
         launch_contract,
         action_contract,
         response_policy,
         callback_origin,
         lifecycle_opts,
         envelope_opts,
         allocation,
         grant_id,
         edge_principal
       ) do
    expires_at = DateTime.add(allocation.issued_at, launch_contract.ttl_seconds, :second)
    actor = value(plan.snapshot, :actor) || %{}
    approval = value(plan.operation, :approval_snapshot) || %{}
    scope = awx_scope(plan, approval)
    response_snapshot = response_policy.snapshot

    with :ok <- dispatch_agent(controller),
         {:ok, target_keys} <- Authority.target_keys(response_snapshot["targets"]) do
      permissions = ActionContract.required_permissions(action_contract)
      principal_type = value(actor, :principal_type)
      principal_id = value(actor, :principal_id)
      owner_id = value(actor, :service_principal_owner_id)

      {:ok,
       %{
         grant_id: grant_id,
         command_id: allocation.command_id,
         allocation: allocation,
         expires_at: expires_at,
         callback_origin: callback_origin,
         lifecycle_opts: Keyword.put(lifecycle_opts, :now, allocation.issued_at),
         envelope_opts: Keyword.put(envelope_opts, :allocation, allocation),
         credential_type_id: value(plan.snapshot["binding"], :callback_credential_type_id),
         organization_id: value(plan.snapshot["binding"], :callback_credential_organization_id),
         credential_slot: value(plan.snapshot["binding"], :callback_credential_slot),
         injector_sha256: value(plan.snapshot["binding"], :callback_credential_injector_digest),
         dispatch_agent_id: edge_principal.agent_id,
         dispatch_partition_id: edge_principal.partition_id,
         grant_attrs: %{
           id: grant_id,
           tenant_id: value(plan.operation, :tenant_id),
           action: launch_contract.action,
           audience: @audience,
           budget: action_contract.max_budget,
           expires_at: expires_at,
           actor_snapshot: %{
             principal_type: principal_type,
             principal_id: principal_id,
             owner_id: owner_id,
             tenant_id: value(actor, :tenant_id),
             authorization_version: value(actor, :authorization_version)
           },
           approval_snapshot: approval,
           policy_snapshot:
             policy_snapshot(plan, launch_contract, approval, response_policy.digest),
           issuance_ceiling: %{
             "permissions" => permissions,
             "actions" => [launch_contract.action],
             "target_keys" => target_keys,
             "tenant_id" => value(plan.operation, :tenant_id),
             "principal_type" => principal_type,
             "principal_id" => principal_id,
             "max_ttl_seconds" => launch_contract.ttl_seconds,
             "success_budget" => action_contract.max_budget
           },
           awx_scope_snapshot: scope,
           response_snapshot: response_snapshot,
           dispatch_agent_id: edge_principal.agent_id,
           dispatch_partition_id: edge_principal.partition_id
         }
       }}
    end
  end

  defp callback_plan(plan, callback) do
    execution =
      plan.execution
      |> Map.put(:callback_reference, callback.grant_id)
      |> Map.update(:metadata, %{}, fn metadata ->
        Map.put(metadata || %{}, "callback_credential_command_id", callback.command_id)
      end)

    Map.put(plan, :execution, execution)
  end

  defp awx_scope(plan, approval) do
    binding = plan.snapshot["binding"]

    %{
      "controller_id" => plan.execution.controller_id,
      "inventory_id" => plan.execution.inventory_id,
      "job_template_id" => plan.execution.job_template_id,
      "project_id" => plan.execution.project_id,
      "scm_revision" => plan.execution.scm_revision,
      "content_sha256" => plan.execution.content_sha256,
      "execution_environment_id" => plan.execution.execution_environment_id,
      "machine_credential_id" => plan.execution.machine_credential_id,
      "credential_ids" => value(plan.execution.credential_snapshot, :credential_ids),
      "ask_credential_on_launch" => value(binding, :ask_credential_on_launch),
      "callback_credential_type_id" => value(binding, :callback_credential_type_id),
      "callback_credential_organization_id" =>
        value(binding, :callback_credential_organization_id),
      "callback_credential_injector_digest" =>
        value(binding, :callback_credential_injector_digest),
      "host_limit" => plan.execution.host_limit,
      "target_count" => length(plan.targets),
      "target_digest" => value(plan.operation, :target_digest),
      "snapshot_digest" => plan.execution.snapshot_digest,
      "targets" => Enum.map(plan.targets, &scope_target/1),
      "binding_id" => value(approval, :binding_id),
      "awx_created_by_id" => value(plan.execution.metadata, :awx_created_by_id)
    }
  end

  defp scope_target(target) do
    %{
      "membership_id" => target.membership_id,
      "controller_id" => target.controller_id,
      "inventory_id" => target.inventory_id,
      "awx_host_id" => target.awx_host_id,
      "canonical_device_uid" => target.canonical_device_uid,
      "host_name" => target.host_name,
      "ansible_host" => target.ansible_host,
      "membership_generation" => target.membership_generation,
      "source_fingerprint" => target.source_fingerprint
    }
  end

  defp policy_snapshot(_plan, contract, approval, response_policy_digest) do
    %{
      "schema" => "serviceradar.automation_callback_policy/v1",
      "action" => contract.action,
      "binding_id" => value(approval, :binding_id),
      "binding_version" => value(approval, :binding_version),
      "version" => contract.policy_version,
      "approval_id" => value(approval, :approval_id),
      "approval_state" => "approved",
      "approval_expires_at" => value(approval, :approval_expires_at),
      "response_policy_digest" => response_policy_digest
    }
  end

  defp dispatch_agent(controller) do
    if is_binary(value(controller, :agent_id)) and value(controller, :agent_id) != "",
      do: :ok,
      else: {:error, :controller_agent_id_missing}
  end

  defp authenticated_edge_principal(controller, opts) do
    resolver =
      Keyword.get(
        opts,
        :edge_principal_resolver,
        &AgentCommandBus.resolve_control_session_evidence/1
      )

    result =
      if is_function(resolver, 1),
        do: resolver.(value(controller, :agent_id)),
        else: {:error, :authenticated_edge_principal_unavailable}

    case result do
      {:ok, evidence} when is_map(evidence) ->
        agent_id = value(evidence, :agent_id)
        partition_id = value(evidence, :partition_id)

        if agent_id == value(controller, :agent_id) and is_binary(partition_id) and
             String.trim(partition_id) != "" do
          {:ok, %{agent_id: agent_id, partition_id: String.trim(partition_id)}}
        else
          {:error, :authenticated_edge_principal_mismatch}
        end

      _ ->
        {:error, :authenticated_edge_principal_unavailable}
    end
  end

  defp now(opts),
    do: opts |> Keyword.get(:now, DateTime.utc_now()) |> DateTime.truncate(:microsecond)

  defp value(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))

  defp value(_map, _key), do: nil
end

defmodule ServiceRadar.Automation.Ansible.CallbackLaunchOrchestrator.Actions do
  @moduledoc false

  @callback persist_callback_plan(map(), map()) :: {:ok, map()} | {:error, term()}
  @callback mark_dispatching(map()) :: :ok | {:error, term()}

  @callback dispatch_callback_credential(struct(), struct()) ::
              {:ok, term()} | {:error, term()}

  @callback revoke_callback_grant(binary(), atom(), keyword()) ::
              {:ok, map()} | {:error, term()}

  @callback mark_callback_dispatch_failed(map(), atom()) :: :ok | {:error, term()}
end

defmodule ServiceRadar.Automation.Ansible.CallbackLaunchOrchestrator.AshActions do
  @moduledoc false
  @behaviour ServiceRadar.Automation.Ansible.CallbackLaunchOrchestrator.Actions

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Automation.Ansible.AutomationCallbackCommandAttempt
  alias ServiceRadar.Automation.Ansible.AutomationExecution
  alias ServiceRadar.Automation.Ansible.AutomationExecutionTarget
  alias ServiceRadar.Automation.Ansible.AutomationOperation
  alias ServiceRadar.Automation.Ansible.CallbackCommandContract
  alias ServiceRadar.Automation.Ansible.CallbackCommandDispatcher
  alias ServiceRadar.Automation.CallbackGrants.Lifecycle
  alias ServiceRadar.Automation.CallbackGrants.RuntimeConfig
  alias ServiceRadar.Automation.LaunchEnvelopes

  @actor SystemActor.system(:ansible_callback_launch_persistence)

  @impl true
  def persist_callback_plan(plan, callback) do
    ServiceRadar.Repo.transaction(fn ->
      with {:ok, operation} <- create_operation(plan.operation),
           {:ok, execution} <- create_execution(plan.execution, operation.id),
           {:ok, targets} <- create_targets(plan.targets, execution.id),
           {:ok, sealed} <- seal(plan, callback, operation, execution),
           :ok <- exact_preallocation(sealed, callback),
           {:ok, attempt} <-
             create_initial_attempt(plan, callback, operation, execution, sealed) do
        %{
          operation: operation,
          execution: execution,
          targets: targets,
          callback: %{
            grant: sealed.grant,
            command_id: sealed.command_id,
            envelope_ref: sealed.envelope_ref,
            attempt: attempt
          }
        }
      else
        {:error, reason} -> ServiceRadar.Repo.rollback(reason)
      end
    end)
  end

  @impl true
  def mark_dispatching(persisted),
    do: ServiceRadar.Automation.Ansible.HardenedRunLauncher.AshActions.mark_dispatching(persisted)

  @impl true
  def dispatch_callback_credential(_controller, attempt),
    do: CallbackCommandDispatcher.dispatch(attempt)

  @impl true
  def revoke_callback_grant(grant_id, reason, lifecycle_opts),
    do: Lifecycle.revoke(grant_id, reason, lifecycle_opts)

  @impl true
  def mark_callback_dispatch_failed(%{operation: operation, execution: execution}, reason) do
    now = DateTime.utc_now()
    diagnostics = %{"reason_code" => Atom.to_string(reason)}

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
  end

  defp seal(plan, callback, operation, execution) do
    scope = value(callback.grant_attrs, :awx_scope_snapshot) || %{}
    response = value(callback.grant_attrs, :response_snapshot) || %{}

    with {:ok, callback_origin} <- RuntimeConfig.configured_callback_origin(),
         :ok <- exact_callback_origin(callback_origin, callback) do
      context_attrs = %{
        tenant_id: plan.operation.tenant_id,
        child_execution_id: execution.id,
        controller_id: plan.execution.controller_id,
        inventory_id: plan.execution.inventory_id,
        job_template_id: plan.execution.job_template_id,
        dispatch_agent_id: callback.dispatch_agent_id,
        dispatch_partition_id: callback.dispatch_partition_id,
        callback_allowed_origin: callback_origin,
        manifest_sha256: value(response, :manifest_sha256),
        scm_revision: value(scope, :scm_revision),
        content_sha256: value(scope, :content_sha256),
        callback_phase: value(response, :phase),
        callback_operation: value(response, :operation),
        callback_state: value(response, :state),
        callback_credential_type_id: value(scope, :callback_credential_type_id),
        callback_credential_organization_id: value(scope, :callback_credential_organization_id),
        callback_credential_injector_sha256: value(scope, :callback_credential_injector_digest),
        expires_at: callback.expires_at
      }

      issue_grant = fn envelope_ref, command_id ->
        attrs =
          callback.grant_attrs
          |> Map.put(:parent_run_id, operation.id)
          |> Map.put(:execution_id, execution.id)
          |> Map.put(:launch_envelope_ref, envelope_ref)

        if command_id == callback.command_id,
          do: Lifecycle.prepare(attrs, callback.lifecycle_opts),
          else: {:error, :callback_command_preallocation_mismatch}
      end

      LaunchEnvelopes.prepare_and_seal(context_attrs, issue_grant, callback.envelope_opts)
    end
  end

  defp exact_callback_origin(origin, callback) do
    if origin == value(callback, :callback_origin),
      do: :ok,
      else: {:error, :automation_callback_origin_changed}
  end

  defp exact_preallocation(sealed, callback) do
    cond do
      sealed.command_id != callback.command_id ->
        {:error, :callback_command_preallocation_mismatch}

      value(sealed.grant, :id) != callback.grant_id ->
        {:error, :callback_grant_preallocation_mismatch}

      true ->
        :ok
    end
  end

  defp create_initial_attempt(_plan, callback, operation, execution, sealed) do
    base = %{
      grant_id: callback.grant_id,
      operation_id: operation.id,
      execution_id: execution.id,
      controller_id: execution.controller_id,
      dispatch_agent_id: callback.dispatch_agent_id,
      dispatch_partition_id: callback.dispatch_partition_id
    }

    with {:ok, request} <-
           CallbackCommandContract.create_credential_request(
             execution,
             callback.grant_attrs.awx_scope_snapshot,
             sealed.envelope_ref
           ),
         {:ok, attrs} <-
           CallbackCommandContract.build_attempt(base, execution, request,
             stage: :create_credential,
             purpose: :credential_creation,
             command_type: "awx.create_callback_credential",
             command_id: callback.command_id,
             deadline_at: callback.expires_at,
             next_attempt_at: callback.allocation.issued_at
           ),
         {:ok, attempt} <- AutomationCallbackCommandAttempt.create_planned(attrs, actor: @actor) do
      {:ok, attempt}
    else
      {:error, reason} -> {:error, {:callback_attempt_create_failed, reason}}
    end
  end

  defp create_operation(attrs) do
    case AutomationOperation.create_operation(attrs, actor: @actor) do
      {:ok, operation} -> {:ok, operation}
      {:error, reason} -> {:error, {:operation_create_failed, reason}}
    end
  end

  defp create_execution(attrs, operation_id) do
    attrs = Map.put(attrs, :operation_id, operation_id)

    case AutomationExecution.create_execution(attrs, actor: @actor) do
      {:ok, execution} -> {:ok, execution}
      {:error, reason} -> {:error, {:execution_create_failed, reason}}
    end
  end

  defp create_targets(targets, execution_id) do
    targets
    |> Enum.reduce_while({:ok, []}, fn attrs, {:ok, acc} ->
      attrs = Map.put(attrs, :execution_id, execution_id)

      case AutomationExecutionTarget.create_target(attrs, actor: @actor) do
        {:ok, target} -> {:cont, {:ok, [target | acc]}}
        {:error, reason} -> {:halt, {:error, {:target_create_failed, reason}}}
      end
    end)
    |> case do
      {:ok, targets} -> {:ok, Enum.reverse(targets)}
      error -> error
    end
  end

  defp value(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))
end
