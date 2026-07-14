defmodule ServiceRadar.Automation.CallbackGrants.AshStore do
  @moduledoc """
  Transactional Ash persistence adapter for automation callback grants.

  SystemActor is used only for persistence policy evaluation. The locked grant
  is converted back to the immutable lifecycle shape and passed to the supplied
  principal-authority hook before any activation, consume, or replay commit.
  """

  @behaviour ServiceRadar.Automation.CallbackGrants.Store

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Automation.CallbackGrants.Audit
  alias ServiceRadar.Automation.CallbackGrants.CanonicalJSON
  alias ServiceRadar.Automation.Callbacks.AuditEvent
  alias ServiceRadar.Automation.Callbacks.Grant
  alias ServiceRadar.Automation.Callbacks.Use
  alias ServiceRadar.Repo

  require Ash.Query

  @actor SystemActor.system(:automation_callback_grant_store)
  @response_schema "serviceradar.remote_access.ssh_ca_bundle/v1"
  @max_response_bytes 262_144
  @cleanup_reconcile_keys MapSet.new([
                            :command_id,
                            :cleanup_kind,
                            :cleanup_mode,
                            :execution_id,
                            :controller_id,
                            :dispatch_agent_id,
                            :dispatch_partition_id,
                            :awx_job_id,
                            :credential_id,
                            :result_status
                          ])

  @impl true
  def create_pending(grant, audit, _context) when is_map(grant) and is_map(audit) do
    with {:ok, attrs} <- grant_create_attrs(grant) do
      transaction(fn ->
        with {:ok, created} <- Grant.create_pending(attrs, actor: @actor),
             {:ok, _audit} <-
               record_audit_event(created, nil, audit,
                 event_type: :mint_pending,
                 outcome: :pending,
                 budget_before: created.budget_limit,
                 budget_after: created.budget_limit
               ) do
          {:ok, to_lifecycle(created)}
        end
      end)
    end
  end

  def create_pending(_grant, _audit, _context), do: {:error, :invalid_pending_grant}

  @impl true
  def fetch(grant_id, _context) when is_binary(grant_id) do
    case Grant.get_by_id(grant_id, actor: @actor) do
      {:ok, %Grant{} = grant} -> {:ok, to_lifecycle(grant)}
      {:ok, nil} -> {:error, :grant_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def fetch(_grant_id, _context), do: {:error, :grant_not_found}

  @impl true
  def bind_credential(grant_id, credential_id, authorize, audit, now, _context)
      when is_binary(grant_id) and is_integer(credential_id) and credential_id > 0 and
             is_function(authorize, 1) do
    transaction(fn ->
      with {:ok, grant} <- lock_grant(grant_id),
           :ok <- unexpired_locked(grant, now) do
        bind_credential_locked(grant, credential_id, authorize, audit, now)
      end
    end)
  end

  @impl true
  def bind_job(grant_id, binding, authorize, audit, now, _context)
      when is_binary(grant_id) and is_map(binding) and is_function(authorize, 1) do
    transaction(fn ->
      with {:ok, grant} <- lock_grant(grant_id),
           :ok <- unexpired_locked(grant, now),
           :ok <- exact_job_binding(grant, binding) do
        bind_job_locked(grant, binding, authorize, audit)
      end
    end)
  end

  @impl true
  def activate(grant_id, binding, authorize, audit, now, _context)
      when is_binary(grant_id) and is_map(binding) and is_function(authorize, 1) do
    transaction(fn ->
      with {:ok, grant} <- lock_grant(grant_id),
           :ok <- unexpired_locked(grant, now),
           :ok <- exact_job_binding(grant, binding) do
        activate_locked(grant, binding, authorize, audit, now)
      end
    end)
  end

  @impl true
  def consume_once(grant_id, attrs, response_bytes, authorize, audit, now, _context)
      when is_binary(grant_id) and is_map(attrs) and is_binary(response_bytes) and
             is_function(authorize, 1) do
    with :ok <- bounded_response(response_bytes),
         :ok <- valid_consume_attrs(attrs),
         :ok <- response_fingerprint_matches(response_bytes, attrs) do
      transaction(fn ->
        with {:ok, grant} <- lock_grant(grant_id),
             :ok <- unexpired_locked(grant, now),
             :ok <- active_or_consumed(grant),
             :ok <- same_grant_idempotency(grant, attrs),
             :ok <- authorize.(to_lifecycle(grant)),
             {:ok, use} <- lock_use(grant_id, attrs.idempotency_key_verifier) do
          consume_locked(grant, use, attrs, response_bytes, audit, now)
        end
      end)
    end
  end

  @impl true
  def transition_terminal(grant_id, state, reason, audit, now, _context)
      when state in [:revoked, :expired] and is_binary(reason) do
    transaction(fn ->
      with {:ok, grant} <- lock_grant(grant_id) do
        transition_terminal_locked(grant, state, reason, audit, now)
      end
    end)
  end

  @impl true
  def transition_terminal_with_cleanup_binding(
        grant_id,
        :revoked,
        reason,
        cleanup_binding,
        audit,
        now,
        _context
      )
      when is_binary(grant_id) and is_binary(reason) and is_map(cleanup_binding) do
    transaction(fn ->
      with {:ok, grant} <- lock_grant(grant_id),
           {:ok, bound} <- bind_cleanup_identity_locked(grant, cleanup_binding) do
        transition_terminal_locked(bound, :revoked, reason, audit, now)
      end
    end)
  end

  def transition_terminal_with_cleanup_binding(
        _grant_id,
        _state,
        _reason,
        _cleanup_binding,
        _audit,
        _now,
        _context
      ),
      do: {:error, :invalid_cleanup_binding_transition}

  @impl true
  def record_cleanup(grant_id, attrs, audit, _context)
      when is_binary(grant_id) and is_map(attrs) and is_map(audit) do
    fn ->
      with {:ok, grant} <- lock_grant(grant_id),
           {:ok, update_attrs} <- cleanup_attrs(grant, attrs),
           {:ok, updated} <- Grant.record_credential_cleanup(grant, update_attrs, actor: @actor),
           {:ok, _audit} <-
             record_audit_event(updated, nil, audit,
               event_type: cleanup_event(update_attrs),
               outcome: cleanup_outcome(update_attrs),
               reason_code: cleanup_reason(update_attrs),
               budget_before: remaining_budget(updated),
               budget_after: remaining_budget(updated)
             ) do
        {:ok, :ok}
      end
    end
    |> transaction()
    |> case do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def reconcile_cleanup_result(grant_id, attrs, _context)
      when is_binary(grant_id) and is_map(attrs) do
    fn ->
      with {:ok, grant} <- lock_grant(grant_id),
           {:ok, attrs} <- normalize_cleanup_reconciliation(attrs),
           :ok <- validate_cleanup_reconciliation(grant, attrs),
           {:ok, update_attrs} <- reconciliation_cleanup_attrs(grant, attrs) do
        reconcile_cleanup_update(grant, update_attrs, attrs)
      end
    end
    |> transaction()
    |> case do
      {:ok, _outcome} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def reconcile_cleanup_result(_grant_id, _attrs, _context),
    do: {:error, :invalid_cleanup_reconciliation}

  @impl true
  def record_audit(audit, _context) when is_map(audit) do
    grant_id = value(audit, :grant_id)

    fn ->
      with {:ok, grant} <- lock_grant(grant_id),
           {:ok, event_attrs} <- standalone_audit_attrs(audit),
           {:ok, _audit} <-
             record_audit_event(grant, nil, audit,
               event_type: event_attrs.event_type,
               outcome: event_attrs.outcome,
               reason_code: event_attrs.reason_code,
               budget_before: remaining_budget(grant),
               budget_after: remaining_budget(grant)
             ) do
        {:ok, :ok}
      end
    end
    |> transaction()
    |> case do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  @spec grant_create_attrs(map()) :: {:ok, map()} | {:error, term()}
  def grant_create_attrs(grant) when is_map(grant) do
    scope = value(grant, :awx_scope_snapshot) || %{}
    response = value(grant, :response_snapshot) || %{}
    ceiling = value(grant, :issuance_ceiling) || %{}
    targets = List.wrap(value(scope, :targets))

    with {:ok, membership_ids} <- membership_ids(targets),
         {:ok, ca_key_set_digest} <- ca_key_set_digest(response),
         {:ok, callback_phase} <- callback_phase(value(response, :phase)),
         {:ok, remote_operation} <- remote_operation(value(response, :operation)),
         {:ok, desired_state} <- desired_state(value(response, :state)),
         {:ok, principal_type} <- principal_type(value(grant, :principal_type)),
         :ok <- required_string(value(grant, :dispatch_agent_id), :dispatch_agent_required),
         :ok <-
           required_string(
             value(grant, :dispatch_partition_id),
             :dispatch_partition_required
           ),
         :ok <- required_string(value(grant, :launch_envelope_ref), :launch_envelope_required) do
      snapshot = %{
        "schema" => "serviceradar.automation_callback_grant_snapshot/v1",
        "target_keys" => value(grant, :target_keys),
        "scope_digest" => value(grant, :scope_digest),
        "approval_digest" => value(grant, :approval_digest),
        "principal_owner_id" => value(grant, :principal_owner_id),
        "awx_scope" => stringify_keys(scope),
        "response" => stringify_keys(response)
      }

      attrs = %{
        grant_id: value(grant, :id),
        operation_id: value(grant, :parent_run_id),
        execution_id: value(grant, :execution_id),
        tenant_id: value(grant, :tenant_id),
        controller_id: value(scope, :controller_id),
        template_binding_id: value(scope, :binding_id),
        inventory_id: value(scope, :inventory_id),
        job_template_id: value(scope, :job_template_id),
        project_id: value(scope, :project_id),
        scm_revision: value(scope, :scm_revision),
        content_sha256: value(scope, :content_sha256),
        action: value(grant, :action),
        action_version: to_string(value(grant, :action_version)),
        audience: value(grant, :audience),
        response_schema_version: @response_schema,
        manifest_sha256: value(response, :manifest_sha256),
        callback_phase: callback_phase,
        remote_access_operation: remote_operation,
        desired_state: desired_state,
        initiator_principal_type: principal_type,
        initiator_principal_id: value(grant, :principal_id),
        authorization_version: value(grant, :authorization_version),
        permission_ceiling: Enum.sort(List.wrap(value(ceiling, :permissions))),
        authority_ceiling: ceiling,
        approval_snapshot: value(grant, :approval_snapshot),
        target_membership_ids: membership_ids,
        target_snapshot: snapshot,
        target_digest: value(scope, :target_digest),
        policy_version: value(grant, :policy_version),
        policy_snapshot: value(grant, :policy_snapshot) || %{},
        policy_digest: value(grant, :policy_digest),
        ca_key_set_digest: ca_key_set_digest,
        token_verifier: value(grant, :verifier_digest),
        token_pepper_version: value(grant, :verifier_key_id),
        idempotency_key_verifier: value(grant, :idempotency_verifier_digest),
        idempotency_pepper_version: value(grant, :idempotency_verifier_key_id),
        budget_limit: value(grant, :budget_total),
        idempotency_policy: :one_logical_read_per_child_policy,
        dispatch_agent_id: value(grant, :dispatch_agent_id),
        dispatch_partition_id: value(grant, :dispatch_partition_id),
        launch_envelope_ref: value(grant, :launch_envelope_ref),
        issued_at: value(grant, :issued_at),
        expires_at: value(grant, :expires_at)
      }

      {:ok, attrs}
    end
  end

  def grant_create_attrs(_grant), do: {:error, :invalid_pending_grant}

  @doc false
  @spec to_lifecycle(Grant.t()) :: map()
  def to_lifecycle(%Grant{} = grant) do
    snapshot = grant.target_snapshot || %{}
    scope = value(snapshot, :awx_scope) || %{}
    response = value(snapshot, :response) || %{}
    job_binding = accepted_job_binding(scope, grant)

    %{
      id: grant.id,
      state: grant.state,
      tenant_id: grant.tenant_id,
      parent_run_id: grant.operation_id,
      execution_id: grant.execution_id,
      principal_type: grant.initiator_principal_type,
      principal_id: grant.initiator_principal_id,
      principal_owner_id: value(snapshot, :principal_owner_id),
      authorization_version: grant.authorization_version,
      issuance_ceiling: grant.authority_ceiling,
      action: grant.action,
      action_version: grant.action_version,
      audience: grant.audience,
      issued_at: grant.issued_at,
      expires_at: grant.expires_at,
      budget_total: grant.budget_limit,
      budget_remaining: remaining_budget(grant),
      target_keys: value(snapshot, :target_keys),
      scope_digest: value(snapshot, :scope_digest),
      approval_digest: value(snapshot, :approval_digest),
      policy_digest: grant.policy_digest,
      approval_snapshot: grant.approval_snapshot,
      policy_snapshot: grant.policy_snapshot,
      policy_version: grant.policy_version,
      awx_scope_snapshot: scope,
      response_snapshot: response,
      binding_verified: grant.state in [:active, :consumed] and not is_nil(grant.awx_job_id),
      job_binding: job_binding,
      ephemeral_credential_id: grant.awx_ephemeral_credential_id,
      dispatch_agent_id: grant.dispatch_agent_id,
      dispatch_partition_id: grant.dispatch_partition_id,
      launch_envelope_ref: grant.launch_envelope_ref,
      verifier_digest: grant.token_verifier,
      verifier_key_id: grant.token_pepper_version,
      idempotency_verifier_digest: grant.idempotency_key_verifier,
      idempotency_verifier_key_id: grant.idempotency_pepper_version,
      credential_cleanup_state: grant.credential_cleanup_state,
      credential_cleanup_attempted_at: grant.credential_cleanup_attempted_at,
      credential_cleanup_completed_at: grant.credential_cleanup_completed_at,
      credential_cleanup_error_code: grant.credential_cleanup_error_code,
      orphan_risk_state: grant.orphan_risk_state
    }
  end

  defp bind_credential_locked(
         %Grant{state: :pending, awx_ephemeral_credential_id: nil} = grant,
         credential_id,
         authorize,
         audit,
         _now
       ) do
    with :ok <- authorize.(to_lifecycle(grant)),
         {:ok, updated} <- record_ephemeral_credential(grant, credential_id),
         {:ok, _audit} <-
           record_audit_event(updated, nil, audit,
             event_type: :credential_created,
             outcome: :succeeded,
             reason_code: :success,
             budget_before: remaining_budget(updated),
             budget_after: remaining_budget(updated)
           ) do
      {:ok, :bound, to_lifecycle(updated)}
    end
  end

  defp bind_credential_locked(
         %Grant{state: :pending, awx_ephemeral_credential_id: credential_id} = grant,
         credential_id,
         authorize,
         _audit,
         _now
       ) do
    with :ok <- authorize.(to_lifecycle(grant)) do
      {:ok, :existing, to_lifecycle(grant)}
    end
  end

  defp bind_credential_locked(%Grant{state: :pending}, _credential_id, _authorize, _audit, _now),
    do: {:error, :callback_credential_conflict}

  defp bind_credential_locked(%Grant{state: state}, _credential_id, _authorize, _audit, _now),
    do: {:error, {:grant_not_pending, state}}

  defp bind_job_locked(
         %Grant{state: :pending, awx_job_id: nil} = grant,
         binding,
         authorize,
         audit
       ) do
    with :ok <- authorize.(to_lifecycle(grant)),
         {:ok, updated} <-
           Grant.bind_job_pending(
             grant,
             %{awx_job_id: value(binding, :job_id)},
             actor: @actor
           ),
         {:ok, _audit} <-
           record_audit_event(updated, nil, audit,
             event_type: :dispatch_succeeded,
             outcome: :succeeded,
             reason_code: :success,
             budget_before: remaining_budget(updated),
             budget_after: remaining_budget(updated)
           ) do
      {:ok, :bound, to_lifecycle(updated)}
    end
  end

  defp bind_job_locked(
         %Grant{state: :pending, awx_job_id: job_id} = grant,
         binding,
         authorize,
         _audit
       ) do
    if job_id == value(binding, :job_id) do
      with :ok <- authorize.(to_lifecycle(grant)) do
        {:ok, :existing, to_lifecycle(grant)}
      end
    else
      {:error, :callback_job_conflict}
    end
  end

  defp bind_job_locked(%Grant{state: state}, _binding, _authorize, _audit),
    do: {:error, {:grant_not_pending, state}}

  defp activate_locked(%Grant{state: :pending} = grant, binding, authorize, audit, now) do
    with :ok <- authorize.(to_lifecycle(grant)),
         {:ok, updated} <-
           Grant.activate_bound(
             grant,
             %{awx_job_id: value(binding, :job_id), activated_at: now},
             actor: @actor
           ),
         {:ok, _audit} <-
           record_audit_event(updated, nil, audit,
             event_type: :binding_activated,
             outcome: :succeeded,
             reason_code: :success,
             budget_before: remaining_budget(updated),
             budget_after: remaining_budget(updated)
           ) do
      {:ok, :activated, to_lifecycle(updated)}
    end
  end

  defp activate_locked(%Grant{state: :active} = grant, _binding, authorize, _audit, _now) do
    with :ok <- authorize.(to_lifecycle(grant)) do
      {:ok, :existing, to_lifecycle(grant)}
    end
  end

  defp activate_locked(%Grant{state: state}, _binding, _authorize, _audit, _now),
    do: {:error, {:grant_not_pending, state}}

  defp consume_locked(grant, nil, attrs, response_bytes, audit, now) do
    if grant.state == :active and remaining_budget(grant) == 1 do
      commit_first_use(grant, attrs, response_bytes, audit, now)
    else
      {:error, :success_budget_consumed}
    end
  end

  defp consume_locked(grant, %Use{state: :committed} = use, attrs, response_bytes, audit, _now) do
    with :ok <- same_idempotency_version(use, attrs),
         :ok <- same_fingerprint(use.request_fingerprint, attrs.request_digest),
         :ok <- same_fingerprint(use.response_fingerprint, attrs.response_digest),
         true <- use.response_bytes == response_bytes || {:error, :committed_response_mismatch},
         true <-
           use.response_size_bytes == byte_size(response_bytes) ||
             {:error, :committed_response_mismatch},
         {:ok, _audit} <-
           record_audit_event(grant, use.id, audit,
             event_type: :callback_replay,
             outcome: :allowed,
             reason_code: :success,
             request_fingerprint: attrs.request_digest,
             response_fingerprint: attrs.response_digest,
             budget_before: remaining_budget(grant),
             budget_after: remaining_budget(grant)
           ) do
      {:ok, :replay, use.response_bytes, to_lifecycle(grant)}
    else
      false -> {:error, :committed_response_mismatch}
      {:error, _} = error -> error
    end
  end

  defp consume_locked(_grant, %Use{}, _attrs, _response_bytes, _audit, _now),
    do: {:error, :idempotency_payload_conflict}

  defp commit_first_use(grant, attrs, response_bytes, audit, now) do
    with {:ok, use} <-
           Use.reserve(
             %{
               grant_id: grant.id,
               idempotency_key_verifier: attrs.idempotency_key_verifier,
               idempotency_pepper_version: attrs.idempotency_pepper_version,
               request_fingerprint: attrs.request_digest,
               reserved_at: now
             },
             actor: @actor
           ),
         {:ok, committed_use} <-
           Use.commit_response(
             use,
             %{
               budget_sequence: 1,
               response_reference: nil,
               response_bytes: response_bytes,
               response_fingerprint: attrs.response_digest,
               response_size_bytes: byte_size(response_bytes),
               response_schema_version: @response_schema,
               policy_version: grant.policy_version,
               committed_at: now
             },
             actor: @actor
           ),
         {:ok, consumed} <-
           Grant.record_consumed(
             grant,
             %{budget_used: 1, consumed_at: now},
             actor: @actor
           ),
         {:ok, _audit} <-
           record_audit_event(consumed, committed_use.id, audit,
             event_type: :callback_allowed,
             outcome: :allowed,
             reason_code: :success,
             request_fingerprint: attrs.request_digest,
             response_fingerprint: attrs.response_digest,
             budget_before: 1,
             budget_after: 0
           ) do
      {:ok, :committed, response_bytes, to_lifecycle(consumed)}
    end
  end

  defp transition_terminal_locked(%Grant{state: state} = grant, state, _reason, _audit, _now)
       when state in [:revoked, :expired], do: {:ok, to_lifecycle(grant)}

  defp transition_terminal_locked(%Grant{state: state}, _target, _reason, _audit, _now)
       when state in [:revoked, :expired], do: {:error, {:grant_already_terminal, state}}

  defp transition_terminal_locked(grant, :revoked, reason, audit, now) do
    orphan_risk_state =
      if is_integer(grant.awx_job_id) and grant.awx_job_id > 0,
        do: :cancel_requested,
        else: grant.orphan_risk_state

    with {:ok, updated} <-
           Grant.record_revoked(
             grant,
             %{
               revoked_at: now,
               revocation_reason: reason,
               orphan_risk_state: orphan_risk_state
             },
             actor: @actor
           ),
         {:ok, _audit} <-
           record_audit_event(updated, nil, audit,
             event_type: :grant_revoked,
             outcome: :succeeded,
             reason_code: :grant_revoked,
             budget_before: remaining_budget(updated),
             budget_after: remaining_budget(updated)
           ) do
      {:ok, to_lifecycle(updated)}
    end
  end

  defp transition_terminal_locked(grant, :expired, _reason, audit, now) do
    with {:ok, updated} <- Grant.record_expired(grant, %{expired_at: now}, actor: @actor),
         {:ok, _audit} <-
           record_audit_event(updated, nil, audit,
             event_type: :grant_expired,
             outcome: :succeeded,
             reason_code: :grant_expired,
             budget_before: remaining_budget(updated),
             budget_after: remaining_budget(updated)
           ) do
      {:ok, to_lifecycle(updated)}
    end
  end

  defp bind_cleanup_identity_locked(%Grant{state: :pending} = grant, binding) do
    credential_id = value(binding, :credential_id)
    job_id = value(binding, :job_id)

    with true <- positive_optional_id?(credential_id),
         true <- positive_optional_id?(job_id),
         true <- is_integer(credential_id) or is_integer(job_id),
         {:ok, grant} <- bind_cleanup_credential(grant, credential_id),
         {:ok, grant} <- bind_cleanup_job(grant, job_id) do
      {:ok, grant}
    else
      false -> {:error, :invalid_verified_cleanup_binding}
      {:error, _reason} = error -> error
    end
  end

  # The selector binding and revocation are committed in one transaction. If a
  # worker crashes after that commit but before it completes its callback
  # attempt, recovery must be able to repeat the contraction without restoring
  # authority or selecting a different object.
  defp bind_cleanup_identity_locked(%Grant{state: :revoked} = grant, binding) do
    credential_id = value(binding, :credential_id)
    job_id = value(binding, :job_id)

    with true <- positive_optional_id?(credential_id),
         true <- positive_optional_id?(job_id),
         true <- is_integer(credential_id) or is_integer(job_id),
         :ok <- exact_optional_cleanup_id(grant.awx_ephemeral_credential_id, credential_id),
         :ok <- exact_optional_cleanup_id(grant.awx_job_id, job_id) do
      {:ok, grant}
    else
      false -> {:error, :invalid_verified_cleanup_binding}
      {:error, _reason} = error -> error
    end
  end

  defp bind_cleanup_identity_locked(%Grant{state: state}, _binding),
    do: {:error, {:grant_not_pending, state}}

  defp exact_optional_cleanup_id(_persisted, nil), do: :ok
  defp exact_optional_cleanup_id(value, value), do: :ok
  defp exact_optional_cleanup_id(_persisted, _requested), do: {:error, :cleanup_binding_conflict}

  defp bind_cleanup_credential(grant, nil), do: {:ok, grant}

  defp bind_cleanup_credential(%Grant{awx_ephemeral_credential_id: nil} = grant, credential_id),
    do: record_ephemeral_credential(grant, credential_id)

  defp bind_cleanup_credential(
         %Grant{awx_ephemeral_credential_id: credential_id} = grant,
         credential_id
       ),
       do: {:ok, grant}

  defp bind_cleanup_credential(_grant, _credential_id),
    do: {:error, :callback_credential_conflict}

  defp bind_cleanup_job(grant, nil), do: {:ok, grant}

  defp bind_cleanup_job(%Grant{awx_job_id: nil} = grant, job_id),
    do: Grant.bind_job_pending(grant, %{awx_job_id: job_id}, actor: @actor)

  defp bind_cleanup_job(%Grant{awx_job_id: job_id} = grant, job_id), do: {:ok, grant}
  defp bind_cleanup_job(_grant, _job_id), do: {:error, :callback_job_conflict}

  defp positive_optional_id?(nil), do: true
  defp positive_optional_id?(value), do: is_integer(value) and value > 0

  defp lock_grant(grant_id) do
    Grant
    |> Ash.Query.filter(id == ^grant_id)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one(actor: @actor)
    |> case do
      {:ok, %Grant{} = grant} -> {:ok, grant}
      {:ok, nil} -> {:error, :grant_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp lock_use(grant_id, verifier) do
    Use
    |> Ash.Query.filter(grant_id == ^grant_id and idempotency_key_verifier == ^verifier)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one(actor: @actor)
  end

  defp record_ephemeral_credential(grant, credential_id) do
    Grant.record_credential_created(grant, %{awx_ephemeral_credential_id: credential_id},
      actor: @actor
    )
  end

  defp exact_job_binding(grant, binding) do
    lifecycle = to_lifecycle(grant)
    scope = lifecycle.awx_scope_snapshot
    credential_id = grant.awx_ephemeral_credential_id
    binding = stringify_keys(binding)
    base_credentials = List.wrap(value(scope, :credential_ids))
    accepted_credentials = List.wrap(value(binding, :credential_ids))

    normalized_scope =
      binding
      |> Map.delete("job_id")
      |> Map.put("credential_ids", base_credentials)

    cond do
      not is_integer(credential_id) or credential_id <= 0 ->
        {:error, :callback_credential_not_bound}

      grant.credential_cleanup_state not in [:pending, :deleting] ->
        {:error, :callback_credential_unavailable}

      Enum.uniq(base_credentials) != base_credentials or
        Enum.uniq(accepted_credentials) != accepted_credentials or
          Enum.sort(accepted_credentials) != Enum.sort(base_credentials ++ [credential_id]) ->
        {:error, :credential_binding_mismatch}

      grant.state == :active and lifecycle.job_binding != binding ->
        {:error, :job_binding_conflict}

      grant.state == :pending and not is_nil(grant.awx_job_id) and
          grant.awx_job_id != value(binding, :job_id) ->
        {:error, :job_binding_conflict}

      grant.state == :pending and not canonical_equal?(scope, normalized_scope) ->
        {:error, :awx_scope_mismatch}

      blank?(value(binding, :job_id)) ->
        {:error, :job_id_required}

      true ->
        :ok
    end
  end

  defp accepted_job_binding(_scope, %Grant{awx_job_id: nil}), do: nil

  defp accepted_job_binding(scope, grant) do
    credentials = List.wrap(value(scope, :credential_ids))

    scope
    |> Map.put("credential_ids", Enum.uniq(credentials ++ [grant.awx_ephemeral_credential_id]))
    |> Map.put("job_id", grant.awx_job_id)
  end

  defp record_audit_event(grant, use_id, lifecycle_audit, opts) do
    attrs = %{
      grant_id: grant.id,
      use_id: use_id,
      event_key: Ash.UUID.generate(),
      event_type: Keyword.fetch!(opts, :event_type),
      outcome: Keyword.fetch!(opts, :outcome),
      tenant_id: grant.tenant_id,
      operation_id: grant.operation_id,
      execution_id: grant.execution_id,
      controller_id: grant.controller_id,
      inventory_id: grant.inventory_id,
      job_template_id: grant.job_template_id,
      awx_job_id: grant.awx_job_id,
      action: grant.action,
      action_version: grant.action_version,
      audience: grant.audience,
      principal_type: grant.initiator_principal_type,
      principal_id: grant.initiator_principal_id,
      reason_code: Keyword.get(opts, :reason_code),
      policy_version: grant.policy_version,
      request_fingerprint:
        Keyword.get(opts, :request_fingerprint, value(lifecycle_audit, :request_digest)),
      response_fingerprint:
        Keyword.get(opts, :response_fingerprint, value(lifecycle_audit, :response_digest)),
      budget_before: Keyword.fetch!(opts, :budget_before),
      budget_after: Keyword.fetch!(opts, :budget_after),
      grant_state: grant.state,
      credential_cleanup_state: grant.credential_cleanup_state,
      occurred_at: DateTime.utc_now()
    }

    AuditEvent.record(attrs, actor: @actor)
  end

  defp cleanup_attrs(grant, attrs) do
    now = DateTime.utc_now()
    credential_state = cleanup_credential_state(grant.credential_cleanup_state, attrs)
    orphan_state = cleanup_orphan_state(grant.orphan_risk_state, attrs)
    credential_touched? = credential_cleanup_touched?(value(attrs, :credential_status))

    update = %{
      credential_cleanup_state: credential_state,
      credential_cleanup_attempted_at:
        if(credential_touched?, do: now, else: grant.credential_cleanup_attempted_at),
      credential_cleanup_completed_at:
        if(credential_state == :deleted,
          do: grant.credential_cleanup_completed_at || if(credential_touched?, do: now)
        ),
      credential_cleanup_error_code:
        cond do
          credential_state == :delete_failed -> "callback_credential_cleanup_failed"
          credential_state == :deleted -> nil
          true -> grant.credential_cleanup_error_code
        end,
      orphan_risk_state: orphan_state
    }

    {:ok, update}
  end

  defp cleanup_credential_state(:deleted, _attrs), do: :deleted

  defp cleanup_credential_state(current, attrs) do
    case value(attrs, :credential_status) do
      :deleted ->
        :deleted

      "deleted" ->
        :deleted

      status when status in [:delete_requested, :deleting, "delete_requested", "deleting"] ->
        :deleting

      status when status in [:delete_failed, :failed, "delete_failed", "failed"] ->
        :delete_failed

      _ ->
        current
    end
  end

  defp credential_cleanup_touched?(status),
    do:
      status in [
        :delete_requested,
        "delete_requested",
        :deleting,
        "deleting",
        :deleted,
        "deleted",
        :delete_failed,
        "delete_failed",
        :failed,
        "failed"
      ]

  defp cleanup_orphan_state(:cancel_confirmed, _attrs), do: :cancel_confirmed

  defp cleanup_orphan_state(current, attrs) do
    case value(attrs, :cancel_status) do
      status when status in [:cancel_requested, "cancel_requested"] ->
        :cancel_requested

      :cancel_failed ->
        :cancel_failed

      "cancel_failed" ->
        :cancel_failed

      status when status in [:cancel_confirmed, :complete, "cancel_confirmed", "complete"] ->
        :cancel_confirmed

      _ ->
        current
    end
  end

  defp cleanup_event(%{credential_cleanup_state: :deleting}), do: :credential_delete_requested

  defp cleanup_event(%{credential_cleanup_state: :delete_failed}), do: :credential_delete_failed

  defp cleanup_event(_attrs), do: :cleanup_completed

  defp cleanup_outcome(%{credential_cleanup_state: :delete_failed}), do: :failed
  defp cleanup_outcome(%{orphan_risk_state: :cancel_failed}), do: :failed
  defp cleanup_outcome(%{credential_cleanup_state: :deleting}), do: :pending
  defp cleanup_outcome(%{orphan_risk_state: :cancel_requested}), do: :pending
  defp cleanup_outcome(_attrs), do: :succeeded

  defp cleanup_reason(%{credential_cleanup_state: :delete_failed}), do: :credential_delete_failed

  defp cleanup_reason(%{orphan_risk_state: :cancel_failed}), do: :cancel_failed
  defp cleanup_reason(_attrs), do: :success

  defp normalize_cleanup_reconciliation(attrs) do
    attrs
    |> Enum.reduce_while({:ok, %{}}, fn {key, item}, {:ok, acc} ->
      normalized = cleanup_reconcile_key(key)

      cond do
        is_nil(normalized) ->
          {:halt, {:error, :unexpected_cleanup_reconciliation_field}}

        Map.has_key?(acc, normalized) ->
          {:halt, {:error, :duplicate_cleanup_reconciliation_field}}

        true ->
          {:cont, {:ok, Map.put(acc, normalized, item)}}
      end
    end)
    |> case do
      {:ok, normalized} ->
        if map_size(normalized) == MapSet.size(@cleanup_reconcile_keys),
          do: {:ok, normalized},
          else: {:error, :incomplete_cleanup_reconciliation}

      {:error, _reason} = error ->
        error
    end
  end

  defp cleanup_reconcile_key(key) when is_atom(key) do
    if MapSet.member?(@cleanup_reconcile_keys, key), do: key
  end

  defp cleanup_reconcile_key(key) when is_binary(key) do
    Enum.find(@cleanup_reconcile_keys, &(Atom.to_string(&1) == key))
  end

  defp cleanup_reconcile_key(_key), do: nil

  defp validate_cleanup_reconciliation(grant, attrs) do
    with {:ok, command_id} <- Ecto.UUID.cast(attrs.command_id),
         true <- command_id == attrs.command_id || {:error, :cleanup_command_id_mismatch},
         true <-
           same_identifier?(grant.execution_id, attrs.execution_id) ||
             {:error, :cleanup_execution_mismatch},
         true <-
           same_identifier?(grant.controller_id, attrs.controller_id) ||
             {:error, :cleanup_controller_mismatch},
         true <-
           grant.dispatch_agent_id == attrs.dispatch_agent_id ||
             {:error, :cleanup_agent_mismatch},
         true <-
           grant.dispatch_partition_id == attrs.dispatch_partition_id ||
             {:error, :cleanup_partition_mismatch},
         true <- grant.awx_job_id == attrs.awx_job_id || {:error, :cleanup_job_mismatch},
         true <-
           grant.awx_ephemeral_credential_id == attrs.credential_id ||
             {:error, :cleanup_credential_mismatch},
         :ok <- cleanup_mode_matches(grant, attrs.cleanup_mode),
         :ok <- cleanup_result_matches_kind(grant, attrs) do
      :ok
    else
      :error -> {:error, :invalid_cleanup_command_id}
      false -> {:error, :cleanup_correlation_mismatch}
      {:error, _reason} = error -> error
    end
  end

  defp cleanup_mode_matches(%Grant{state: state, awx_job_id: job_id}, mode)
       when state in [:active, :consumed, :revoked, :expired] and is_integer(job_id) and
              mode in [:post_activation, "post_activation"],
       do: :ok

  defp cleanup_mode_matches(%Grant{state: state}, mode)
       when state in [:consumed, :revoked] and mode in [:consumed, "consumed"], do: :ok

  defp cleanup_mode_matches(%Grant{state: :revoked}, mode)
       when mode in [:revoked, :job_terminal, "revoked", "job_terminal"], do: :ok

  defp cleanup_mode_matches(%Grant{state: :expired}, mode) when mode in [:expired, "expired"],
    do: :ok

  defp cleanup_mode_matches(_grant, _mode), do: {:error, :cleanup_mode_mismatch}

  defp cleanup_result_matches_kind(grant, %{cleanup_kind: kind, result_status: status})
       when kind in [:credential_delete, "credential_delete"] and
              status in [:deleted, :delete_failed, "deleted", "delete_failed"] do
    if is_integer(grant.awx_ephemeral_credential_id) and grant.awx_ephemeral_credential_id > 0,
      do: :ok,
      else: {:error, :cleanup_credential_missing}
  end

  defp cleanup_result_matches_kind(grant, %{cleanup_kind: kind, result_status: status})
       when kind in [:job_cancel, "job_cancel"] and
              status in [:cancel_requested, :cancel_failed, "cancel_requested", "cancel_failed"] do
    if is_integer(grant.awx_job_id) and grant.awx_job_id > 0 and
         grant.state in [:revoked, :expired],
       do: :ok,
       else: {:error, :cleanup_job_missing}
  end

  defp cleanup_result_matches_kind(_grant, _attrs), do: {:error, :cleanup_result_kind_mismatch}

  defp reconciliation_cleanup_attrs(grant, attrs) do
    cleanup =
      case {attrs.cleanup_kind, attrs.result_status} do
        {kind, status} when kind in [:credential_delete, "credential_delete"] ->
          %{credential_status: status}

        {kind, status} when kind in [:job_cancel, "job_cancel"] ->
          %{cancel_status: status}
      end

    cleanup_attrs(grant, cleanup)
  end

  defp reconcile_cleanup_update(grant, update_attrs, attrs) do
    if grant.credential_cleanup_state == update_attrs.credential_cleanup_state and
         grant.orphan_risk_state == update_attrs.orphan_risk_state do
      {:ok, :existing}
    else
      with {:ok, updated} <-
             Grant.record_credential_cleanup(grant, update_attrs, actor: @actor),
           {:ok, audit} <-
             Audit.attrs(:grant_cleanup, to_lifecycle(updated), %{
               cleanup_status: :complete,
               cancel_status: updated.orphan_risk_state,
               credential_status: updated.credential_cleanup_state
             }),
           {:ok, _event} <-
             record_audit_event(updated, nil, audit,
               event_type: reconciliation_event(attrs),
               outcome: reconciliation_outcome(attrs),
               reason_code: reconciliation_reason(attrs),
               budget_before: remaining_budget(updated),
               budget_after: remaining_budget(updated)
             ) do
        {:ok, :updated}
      end
    end
  end

  defp reconciliation_event(%{cleanup_kind: kind, result_status: status})
       when kind in [:credential_delete, "credential_delete"] and status in [:deleted, "deleted"],
       do: :credential_deleted

  defp reconciliation_event(%{cleanup_kind: kind})
       when kind in [:credential_delete, "credential_delete"],
       do: :credential_delete_failed

  defp reconciliation_event(_attrs), do: :cleanup_completed

  defp reconciliation_outcome(%{result_status: status})
       when status in [:delete_failed, :cancel_failed, "delete_failed", "cancel_failed"],
       do: :failed

  defp reconciliation_outcome(_attrs), do: :succeeded

  defp reconciliation_reason(%{result_status: status})
       when status in [:delete_failed, "delete_failed"],
       do: :credential_delete_failed

  defp reconciliation_reason(%{result_status: status})
       when status in [:cancel_failed, "cancel_failed"],
       do: :cancel_failed

  defp reconciliation_reason(_attrs), do: :success

  defp same_identifier?(left, right), do: to_string(left) == to_string(right)

  defp transaction(fun) when is_function(fun, 0) do
    fn ->
      case fun.() do
        {:ok, _rest} = result -> result
        {:ok, _outcome, _grant} = result -> result
        {:ok, _outcome, _response, _grant} = result -> result
        {:error, reason} -> Repo.rollback(reason)
      end
    end
    |> Repo.transaction()
    |> case do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp unexpired_locked(%Grant{expires_at: %DateTime{} = expires_at}, %DateTime{} = now) do
    if DateTime.before?(now, expires_at),
      do: :ok,
      else: {:error, :grant_expired}
  end

  defp unexpired_locked(_grant, _now), do: {:error, :grant_expired}

  defp active_or_consumed(%Grant{state: state}) when state in [:active, :consumed], do: :ok
  defp active_or_consumed(%Grant{state: state}), do: {:error, {:grant_not_active, state}}

  defp valid_consume_attrs(attrs) do
    cond do
      not is_binary(value(attrs, :idempotency_key_verifier)) ->
        {:error, :invalid_idempotency_verifier}

      byte_size(value(attrs, :idempotency_key_verifier)) != 32 ->
        {:error, :invalid_idempotency_verifier}

      blank?(value(attrs, :idempotency_pepper_version)) ->
        {:error, :invalid_idempotency_verifier}

      not digest?(value(attrs, :request_digest)) ->
        {:error, :invalid_request_fingerprint}

      not digest?(value(attrs, :response_digest)) ->
        {:error, :invalid_response_fingerprint}

      true ->
        :ok
    end
  end

  defp bounded_response(bytes) when byte_size(bytes) <= @max_response_bytes, do: :ok
  defp bounded_response(_bytes), do: {:error, :callback_response_too_large}

  defp response_fingerprint_matches(response_bytes, attrs) do
    expected = value(attrs, :response_digest)
    actual = CanonicalJSON.sha256(response_bytes)

    if byte_size(expected) == byte_size(actual) and :crypto.hash_equals(expected, actual),
      do: :ok,
      else: {:error, :invalid_response_fingerprint}
  end

  defp same_idempotency_version(use, attrs) do
    if use.idempotency_pepper_version == attrs.idempotency_pepper_version,
      do: :ok,
      else: {:error, :idempotency_payload_conflict}
  end

  defp same_grant_idempotency(grant, attrs) do
    expected = grant.idempotency_key_verifier
    actual = value(attrs, :idempotency_key_verifier)

    if grant.idempotency_pepper_version == value(attrs, :idempotency_pepper_version) and
         is_binary(expected) and is_binary(actual) and byte_size(expected) == byte_size(actual) and
         :crypto.hash_equals(expected, actual),
       do: :ok,
       else: {:error, :invalid_idempotency_key}
  end

  defp same_fingerprint(left, right)
       when is_binary(left) and is_binary(right) and byte_size(left) == byte_size(right) do
    if :crypto.hash_equals(left, right),
      do: :ok,
      else: {:error, :idempotency_payload_conflict}
  end

  defp same_fingerprint(_left, _right), do: {:error, :idempotency_payload_conflict}

  defp membership_ids(targets) when is_list(targets) and targets != [] do
    ids = Enum.map(targets, &value(&1, :membership_id))

    cond do
      Enum.any?(ids, &blank?/1) -> {:error, :target_membership_id_required}
      Enum.uniq(ids) != ids -> {:error, :duplicate_target_membership_id}
      true -> {:ok, ids}
    end
  end

  defp membership_ids(_targets), do: {:error, :target_membership_id_required}

  defp ca_key_set_digest(response) do
    keys =
      response
      |> value(:targets)
      |> List.wrap()
      |> Enum.flat_map(&List.wrap(value(&1, :ca_keys)))
      |> Enum.sort_by(&{to_string(value(&1, :id)), to_string(value(&1, :fingerprint))})

    CanonicalJSON.digest(keys)
  end

  defp callback_phase("preflight"), do: {:ok, :preflight}
  defp callback_phase("stage"), do: {:ok, :stage}
  defp callback_phase("verify"), do: {:ok, :verify}
  defp callback_phase("commit"), do: {:ok, :commit}

  defp callback_phase(value) when value in [:preflight, :stage, :verify, :commit],
    do: {:ok, value}

  defp callback_phase(_value), do: {:error, :invalid_callback_phase}

  defp remote_operation(value) when value in ["enroll", :enroll], do: {:ok, :enroll}
  defp remote_operation(_value), do: {:error, :operation_outside_deployment_maximum}

  defp desired_state(value) when value in ["present", :present], do: {:ok, :present}
  defp desired_state(_value), do: {:error, :state_outside_deployment_maximum}

  defp principal_type(value) when value in ["human", :human], do: {:ok, :human}

  defp principal_type(value) when value in ["service_principal", :service_principal],
    do: {:ok, :service_principal}

  defp principal_type(_value), do: {:error, :initiating_principal_required}

  defp reason_code(reason) when reason in [:invalid_callback_grant, "invalid_callback_grant"],
    do: :misuse_detected

  defp reason_code(reason) when reason in [:grant_pending, "grant_pending"], do: :grant_pending
  defp reason_code(reason) when reason in [:grant_expired, "grant_expired"], do: :grant_expired
  defp reason_code(reason) when reason in [:grant_revoked, "grant_revoked"], do: :grant_revoked

  defp reason_code(reason)
       when reason in [:current_permission_denied, "current_permission_denied"],
       do: :permission_missing

  defp reason_code(reason)
       when reason in [
              :principal_disabled,
              :principal_changed,
              "principal_disabled",
              "principal_changed"
            ],
       do: :principal_disabled

  defp reason_code(reason) when reason in [:tenant_changed, "tenant_changed"],
    do: :tenant_mismatch

  defp reason_code(reason)
       when reason in [:target_no_longer_authorized, "target_no_longer_authorized"],
       do: :target_drift

  defp reason_code(reason) when reason in [:target_policy_changed, "target_policy_changed"],
    do: :policy_drift

  defp reason_code(reason) when reason in [:awx_binding_changed, "awx_binding_changed"],
    do: :binding_mismatch

  defp reason_code(reason)
       when reason in [
              :job_binding_changed,
              :job_not_active,
              "job_binding_changed",
              "job_not_active"
            ], do: :job_mismatch

  defp reason_code(reason) when reason in [:success_budget_consumed, "success_budget_consumed"],
    do: :budget_consumed

  defp reason_code(reason)
       when reason in [:idempotency_payload_conflict, "idempotency_payload_conflict"],
       do: :idempotency_conflict

  defp reason_code(reason) when reason in [:invalid_idempotency_key, "invalid_idempotency_key"],
    do: :idempotency_conflict

  defp reason_code(_reason), do: :authorization_denied

  defp standalone_audit_attrs(audit) do
    case value(audit, :event) do
      event when event in [:callback_pending, "callback_pending"] ->
        {:ok, %{event_type: :callback_pending, outcome: :pending, reason_code: :grant_pending}}

      event when event in [:callback_denied, "callback_denied"] ->
        {:ok,
         %{
           event_type: :callback_denied,
           outcome: :denied,
           reason_code: reason_code(value(audit, :reason))
         }}

      _ ->
        {:error, :unsupported_callback_audit_event}
    end
  end

  defp remaining_budget(grant), do: max(grant.budget_limit - grant.budget_used, 0)

  defp canonical_equal?(left, right) do
    case {CanonicalJSON.digest(left), CanonicalJSON.digest(right)} do
      {{:ok, left}, {:ok, right}} when byte_size(left) == byte_size(right) ->
        :crypto.hash_equals(left, right)

      _ ->
        false
    end
  end

  defp required_string(value, _reason) when is_binary(value) and value != "", do: :ok
  defp required_string(_value, reason), do: {:error, reason}

  defp digest?(value), do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{64}\z/, value)

  defp blank?(value), do: is_nil(value) or value == ""

  defp stringify_keys(value) when is_map(value) do
    Map.new(value, fn {key, item} ->
      key = if is_atom(key), do: Atom.to_string(key), else: key
      {key, stringify_keys(item)}
    end)
  end

  defp stringify_keys(value) when is_list(value), do: Enum.map(value, &stringify_keys/1)
  defp stringify_keys(value), do: value

  defp value(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp value(_map, _key), do: nil
end
