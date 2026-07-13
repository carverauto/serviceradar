defmodule ServiceRadar.Automation.CallbackGrants.Lifecycle do
  @moduledoc """
  Purely orchestrated callback-grant lifecycle.

  Persistence, current authorization, keyed verification, time, and external
  cleanup are injected adapters. The store owns all row locks and atomic state,
  idempotency, budget, and audit commits.
  """

  alias ServiceRadar.Automation.CallbackGrants.ActionContract
  alias ServiceRadar.Automation.CallbackGrants.Audit
  alias ServiceRadar.Automation.CallbackGrants.Authority
  alias ServiceRadar.Automation.CallbackGrants.CanonicalJSON
  alias ServiceRadar.Automation.CallbackGrants.HMACKeyedVerifier
  alias ServiceRadar.Automation.CallbackGrants.NoopCleanup
  alias ServiceRadar.Automation.CallbackGrants.SshCaBundleResponse
  alias ServiceRadar.Automation.CallbackGrants.Token

  @audience "serviceradar.awx.callback/v1"

  @scope_required MapSet.new(
                    ~w(controller_id inventory_id job_template_id project_id scm_revision content_sha256 execution_environment_id machine_credential_id credential_ids callback_credential_type_id callback_credential_id callback_credential_injector_digest host_limit target_count target_digest snapshot_digest targets binding_id awx_created_by_id)
                  )

  @scope_optional MapSet.new()

  @type opts :: keyword()

  @doc "Creates an unusable pending grant and returns its bearer exactly once."
  @spec prepare(map(), opts()) :: {:ok, map()} | {:error, term()}
  def prepare(attrs, opts) when is_map(attrs) and is_list(opts) do
    now = now(opts)
    action = value(attrs, :action)

    with {:ok, contract} <- ActionContract.fetch(action),
         :ok <- ActionContract.validate_deployment(contract, value(attrs, :response_snapshot)),
         {:ok, draft} <- prepare_draft(attrs, contract, now),
         {:ok, current} <- current_authority(:issue, draft, opts),
         :ok <- Authority.validate_issue(draft, current, contract),
         :ok <- validate_response_snapshot(draft),
         {:ok, issued} <- issue_token(opts),
         grant_attrs =
           draft
           |> Map.put(:verifier_key_id, issued.verifier_key_id)
           |> Map.put(:verifier_digest, issued.verifier_digest),
         {:ok, audit} <- Audit.attrs(:grant_pending, grant_attrs),
         {:ok, grant} <- store(opts).create_pending(grant_attrs, audit, store_context(opts)) do
      {:ok, %{grant: pending_result(grant), bearer: issued.bearer}}
    end
  end

  def prepare(_attrs, _opts), do: {:error, :invalid_callback_grant}

  @doc "Binds a pending grant to one verified controller-local AWX job."
  @spec activate(binary(), map(), opts()) :: {:ok, map()} | {:error, term()}
  def activate(grant_id, job_binding, opts)
      when is_binary(grant_id) and is_map(job_binding) and is_list(opts) do
    now = now(opts)

    with {:ok, grant} <- store(opts).fetch(grant_id, store_context(opts)),
         :ok <- not_expired(grant, now),
         {:ok, contract} <- ActionContract.fetch(value(grant, :action)),
         {:ok, binding} <- validate_job_binding(grant, job_binding),
         authorize = activation_hook(binding, contract, opts),
         {:ok, audit} <-
           Audit.attrs(:grant_activated, grant, %{job_id: binding["job_id"]}),
         {:ok, outcome, activated} <-
           store(opts).activate(
             grant_id,
             binding,
             authorize,
             audit,
             now,
             store_context(opts)
           ) do
      {:ok, public_result(activated, %{outcome: outcome})}
    else
      {:error, :grant_expired} -> expire_and_deny(grant_id, opts)
      {:error, _} = error -> error
    end
  end

  def activate(_grant_id, _job_binding, _opts), do: {:error, :invalid_activation}

  @doc "Consumes or same-key replays a callback response after current reauthorization."
  @spec consume(binary(), binary(), binary(), map(), opts()) ::
          {:ok, map()} | {:retry, map()} | {:error, term()}
  def consume(grant_id, bearer, idempotency_key, request, opts)
      when is_binary(grant_id) and is_binary(bearer) and is_binary(idempotency_key) and
             is_map(request) and is_list(opts) do
    now = now(opts)

    with {:ok, grant} <- store(opts).fetch(grant_id, store_context(opts)),
         :ok <- verify_token(bearer, grant, opts),
         :ok <- not_expired(grant, now) do
      consume_by_state(grant, idempotency_key, request, now, opts)
    else
      {:error, :invalid_callback_grant} = error ->
        audit_denial(grant_id, :invalid_callback_grant, opts)
        error

      {:error, :grant_expired} ->
        expire_and_deny(grant_id, opts)

      {:error, _} = error ->
        error
    end
  end

  def consume(_grant_id, _bearer, _idempotency_key, _request, _opts),
    do: {:error, :invalid_callback_request}

  @doc "Revokes a grant before attempting external cancellation/credential cleanup."
  @spec revoke(binary(), binary() | atom(), opts()) :: {:ok, map()} | {:error, term()}
  def revoke(grant_id, reason, opts), do: terminate(grant_id, :revoked, reason, :revoked, opts)

  @doc "Expires a grant before attempting external cancellation/credential cleanup."
  @spec expire(binary(), opts()) :: {:ok, map()} | {:error, term()}
  def expire(grant_id, opts), do: terminate(grant_id, :expired, :ttl_elapsed, :expired, opts)

  @doc "Revokes callback authority when the bound AWX child becomes terminal."
  @spec job_terminal(binary(), binary() | atom(), opts()) :: {:ok, map()} | {:error, term()}
  def job_terminal(grant_id, job_status, opts),
    do: terminate(grant_id, :revoked, {:job_terminal, job_status}, :job_terminal, opts)

  defp prepare_draft(attrs, contract, now) do
    actor = value(attrs, :actor_snapshot) || %{}
    response_snapshot = value(attrs, :response_snapshot) || %{}
    targets = value(response_snapshot, :targets)
    awx_scope = value(attrs, :awx_scope_snapshot) || %{}

    with :ok <- required_id(value(attrs, :id), :grant_id_required),
         :ok <- required_id(value(attrs, :tenant_id), :tenant_required),
         :ok <- required_id(value(attrs, :parent_run_id), :parent_run_required),
         :ok <- required_id(value(attrs, :execution_id), :execution_required),
         true <- value(attrs, :audience) == @audience || {:error, :invalid_callback_audience},
         {:ok, expires_at} <- datetime(value(attrs, :expires_at)),
         :ok <- validate_ttl(now, expires_at, contract.max_ttl_seconds),
         true <-
           value(attrs, :budget) == contract.max_budget ||
             {:error, :invalid_callback_budget},
         {:ok, target_keys} <- Authority.target_keys(List.wrap(targets)),
         {:ok, scope_digest} <- validate_scope(awx_scope),
         {:ok, approval_digest} <- snapshot_digest(value(attrs, :approval_snapshot)),
         {:ok, policy_digest} <- snapshot_digest(value(attrs, :policy_snapshot)),
         true <-
           to_string(value(actor, :tenant_id)) == to_string(value(attrs, :tenant_id)) ||
             {:error, :actor_tenant_mismatch} do
      {:ok,
       %{
         id: value(attrs, :id),
         state: :pending,
         tenant_id: value(attrs, :tenant_id),
         parent_run_id: value(attrs, :parent_run_id),
         execution_id: value(attrs, :execution_id),
         principal_type: value(actor, :principal_type),
         principal_id: value(actor, :principal_id),
         principal_owner_id: value(actor, :owner_id),
         authorization_version: value(actor, :authorization_version),
         issuance_ceiling: value(attrs, :issuance_ceiling),
         action: contract.action,
         action_version: contract.version,
         audience: @audience,
         issued_at: now,
         expires_at: expires_at,
         budget_total: contract.max_budget,
         budget_remaining: contract.max_budget,
         target_keys: target_keys,
         scope_digest: scope_digest,
         approval_digest: approval_digest,
         policy_digest: policy_digest,
         approval_snapshot: value(attrs, :approval_snapshot),
         policy_version: value(value(attrs, :policy_snapshot) || %{}, :version),
         awx_scope_snapshot: awx_scope,
         response_snapshot: response_snapshot,
         binding_verified: false,
         job_binding: nil,
         ephemeral_credential_id: value(attrs, :ephemeral_credential_id)
       }}
    else
      false -> {:error, :invalid_callback_grant}
      {:error, _} = error -> error
    end
  end

  defp validate_response_snapshot(draft) do
    hypothetical = Map.put(draft, :binding_verified, true)

    with {:ok, request} <- SshCaBundleResponse.expected_request(hypothetical),
         {:ok, _built} <- SshCaBundleResponse.build(hypothetical, request) do
      :ok
    end
  end

  defp consume_by_state(grant, idempotency_key, request, now, opts) do
    case value(grant, :state) do
      :pending ->
        {:retry,
         %{
           status: 409,
           code: "grant_pending",
           retryable: true,
           retry_after_seconds: 1
         }}

      state when state in [:active, :consumed] ->
        consume_active(grant, idempotency_key, request, now, opts)

      state ->
        {:error, {:grant_not_active, state}}
    end
  end

  defp consume_active(grant, idempotency_key, request, now, opts) do
    with :ok <- validate_idempotency_key(idempotency_key),
         {:ok, built} <- SshCaBundleResponse.build(grant, request),
         {:ok, request_digest} <- CanonicalJSON.digest(request),
         {:ok, contract} <- ActionContract.fetch(value(grant, :action)),
         {:ok, idempotency} <- keyed_idempotency(idempotency_key, grant, opts),
         consume_attrs = %{
           idempotency_key_verifier: idempotency.verifier,
           idempotency_pepper_version: idempotency.key_id,
           request_digest: request_digest,
           response_digest: built.digest,
           action: value(grant, :action)
         },
         authorize = use_hook(contract, opts),
         {:ok, audit} <-
           Audit.attrs(:callback_consumed, grant, %{
             request_digest: request_digest,
             response_digest: built.digest
           }),
         {:ok, outcome, response_bytes, committed_grant} <-
           store(opts).consume_once(
             value(grant, :id),
             consume_attrs,
             built.bytes,
             authorize,
             audit,
             now,
             store_context(opts)
           ),
         true <- response_bytes == built.bytes || {:error, :committed_response_mismatch},
         :ok <- maybe_cleanup_consumed(outcome, committed_grant, opts) do
      {:ok,
       %{
         status: 200,
         content_type: "application/json",
         body: response_bytes,
         response_digest: built.digest,
         replay: outcome == :replay
       }}
    else
      false -> {:error, :committed_response_mismatch}
      {:error, _} = error -> error
    end
  end

  defp activation_hook(binding, contract, opts) do
    fn locked_grant ->
      candidate =
        locked_grant
        |> Map.put(:job_binding, binding)
        |> Map.put(:binding_verified, true)

      with {:ok, current} <- current_authority(:activate, candidate, opts) do
        Authority.reauthorize(:activate, candidate, current, contract)
      end
    end
  end

  defp use_hook(contract, opts) do
    fn locked_grant ->
      with {:ok, current} <- current_authority(:use, locked_grant, opts) do
        Authority.reauthorize(:use, locked_grant, current, contract)
      end
    end
  end

  defp validate_scope(scope) when is_map(scope) do
    with {:ok, scope} <- string_map(scope),
         keys = MapSet.new(Map.keys(scope)),
         true <- MapSet.subset?(@scope_required, keys) || {:error, :incomplete_awx_scope},
         true <-
           MapSet.subset?(keys, MapSet.union(@scope_required, @scope_optional)) ||
             {:error, :unexpected_awx_scope_field},
         true <-
           (is_list(scope["targets"]) and scope["targets"] != []) ||
             {:error, :awx_targets_required},
         true <-
           scope["target_count"] == length(scope["targets"]) ||
             {:error, :awx_target_count_mismatch},
         true <- is_list(scope["credential_ids"] || []) || {:error, :invalid_credential_ids},
         :ok <- required_id(scope["controller_id"], :controller_id_required),
         :ok <- required_id(scope["inventory_id"], :inventory_id_required),
         :ok <- required_id(scope["job_template_id"], :job_template_id_required),
         :ok <- required_id(scope["project_id"], :project_id_required),
         :ok <- required_id(scope["execution_environment_id"], :execution_environment_required),
         :ok <- required_id(scope["machine_credential_id"], :machine_credential_required),
         :ok <- required_id(scope["callback_credential_type_id"], :callback_credential_required),
         :ok <-
           required_id(scope["callback_credential_id"], :callback_credential_instance_required),
         true <-
           digest?(scope["callback_credential_injector_digest"], 64) ||
             {:error, :invalid_callback_injector_digest},
         true <- digest?(scope["scm_revision"], 40..64) || {:error, :invalid_scm_revision},
         true <- digest?(scope["content_sha256"], 64) || {:error, :invalid_content_digest},
         true <- digest?(scope["target_digest"], 64) || {:error, :invalid_target_digest},
         true <- digest?(scope["snapshot_digest"], 64) || {:error, :invalid_snapshot_digest},
         true <-
           (is_binary(scope["host_limit"]) and scope["host_limit"] != "") ||
             {:error, :host_limit_required},
         {:ok, digest} <- CanonicalJSON.digest(scope) do
      {:ok, digest}
    else
      false -> {:error, :invalid_awx_scope}
      {:error, _} = error -> error
    end
  end

  defp validate_scope(_scope), do: {:error, :invalid_awx_scope}

  defp validate_job_binding(grant, binding) do
    with {:ok, expected_scope} <- string_map(value(grant, :awx_scope_snapshot)),
         {:ok, binding} <- string_map(binding),
         true <-
           MapSet.new(Map.keys(binding)) ==
             MapSet.put(MapSet.new(Map.keys(expected_scope)), "job_id") ||
             {:error, :incomplete_job_binding},
         :ok <- required_id(binding["job_id"], :job_id_required),
         scope = Map.delete(binding, "job_id"),
         {:ok, digest} <- validate_scope(scope),
         true <-
           secure_equal(digest, value(grant, :scope_digest)) ||
             {:error, :awx_scope_mismatch} do
      {:ok, binding}
    else
      false -> {:error, :invalid_job_binding}
      {:error, _} = error -> error
    end
  end

  defp terminate(grant_id, state, reason, cleanup_mode, opts)
       when is_binary(grant_id) and is_list(opts) do
    now = now(opts)
    reason = inspect_reason(reason)

    with {:ok, grant} <- store(opts).fetch(grant_id, store_context(opts)),
         {:ok, audit} <- Audit.attrs(state, grant, %{reason: reason}),
         {:ok, terminal_grant} <-
           store(opts).transition_terminal(
             grant_id,
             state,
             reason,
             audit,
             now,
             store_context(opts)
           ),
         :ok <- run_cleanup(terminal_grant, cleanup_mode, opts) do
      {:ok, public_result(terminal_grant)}
    end
  end

  defp terminate(_grant_id, _state, _reason, _cleanup_mode, _opts),
    do: {:error, :invalid_terminal_transition}

  defp expire_and_deny(grant_id, opts) do
    case expire(grant_id, opts) do
      {:ok, _grant} -> {:error, :grant_expired}
      {:error, _} = error -> error
    end
  end

  defp maybe_cleanup_consumed(:committed, grant, opts), do: run_cleanup(grant, :consumed, opts)
  defp maybe_cleanup_consumed(:replay, _grant, _opts), do: :ok

  defp run_cleanup(grant, mode, opts) do
    cleanup = Keyword.get(opts, :cleanup, NoopCleanup)
    context = Keyword.get(opts, :cleanup_context)
    safe_grant = Audit.safe_grant(grant)

    cleanup_attrs =
      case cleanup.cleanup(safe_grant, mode, context) do
        {:ok, attrs} when is_map(attrs) -> sanitize_cleanup(attrs, :ok)
        {:error, attrs} when is_map(attrs) -> sanitize_cleanup(attrs, :cancel_failed)
        _ -> %{cleanup_status: :failed, cancel_status: :unknown}
      end

    record_cleanup(grant, cleanup_attrs, opts)
  end

  defp record_cleanup(grant, cleanup_attrs, opts) do
    adapter = store(opts)

    if function_exported?(adapter, :record_cleanup, 4) do
      with {:ok, audit} <-
             Audit.attrs(:grant_cleanup, grant, %{
               cleanup_status: cleanup_attrs.cleanup_status,
               cancel_status: cleanup_attrs.cancel_status,
               credential_status: cleanup_attrs.credential_status
             }) do
        adapter.record_cleanup(value(grant, :id), cleanup_attrs, audit, store_context(opts))
      end
    else
      :ok
    end
  end

  defp sanitize_cleanup(attrs, fallback) do
    %{
      cleanup_status: value(attrs, :cleanup_status) || fallback,
      cancel_status: value(attrs, :job_cleanup) || value(attrs, :cancel_status) || :unknown,
      credential_status:
        value(attrs, :credential_cleanup) || value(attrs, :credential_status) || :unknown
    }
  end

  defp verify_token(bearer, grant, opts) do
    verifier = Keyword.get(opts, :verifier, HMACKeyedVerifier)
    Token.verify(bearer, grant, verifier, Keyword.fetch!(opts, :verifier_config))
  end

  defp issue_token(opts) do
    verifier = Keyword.get(opts, :verifier, HMACKeyedVerifier)
    Token.issue(verifier, Keyword.fetch!(opts, :verifier_config), opts)
  end

  defp current_authority(stage, grant, opts) do
    authorizer = Keyword.fetch!(opts, :authorizer)

    authorizer.current_authority(
      stage,
      Audit.safe_grant(grant),
      Keyword.get(opts, :authority_context)
    )
  end

  defp audit_denial(grant_id, reason, opts) do
    adapter = store(opts)

    if function_exported?(adapter, :record_audit, 2) do
      case adapter.fetch(grant_id, store_context(opts)) do
        {:ok, grant} ->
          with {:ok, audit} <- Audit.attrs(:callback_denied, grant, %{reason: to_string(reason)}) do
            adapter.record_audit(audit, store_context(opts))
          end

        _ ->
          :ok
      end
    end

    :ok
  end

  defp pending_result(grant) do
    %{
      id: value(grant, :id),
      state: :pending,
      action: value(grant, :action),
      expires_at: value(grant, :expires_at),
      retryable: true
    }
  end

  defp public_result(grant, extra \\ %{}) do
    binding = value(grant, :job_binding) || %{}

    Map.merge(
      %{
        id: value(grant, :id),
        state: value(grant, :state),
        action: value(grant, :action),
        expires_at: value(grant, :expires_at),
        job_id: value(binding, :job_id)
      },
      extra
    )
  end

  defp validate_ttl(now, expires_at, maximum_seconds) do
    seconds = DateTime.diff(expires_at, now, :second)
    if seconds in 1..maximum_seconds, do: :ok, else: {:error, :invalid_callback_ttl}
  end

  defp not_expired(grant, now) do
    case datetime(value(grant, :expires_at)) do
      {:ok, expires_at} ->
        if DateTime.after?(expires_at, now), do: :ok, else: {:error, :grant_expired}

      _ ->
        {:error, :grant_expired}
    end
  end

  defp validate_idempotency_key(key) when is_binary(key) and byte_size(key) in 32..128 do
    if Regex.match?(~r/\A[A-Za-z0-9._~-]+\z/, key),
      do: :ok,
      else: {:error, :invalid_idempotency_key}
  end

  defp validate_idempotency_key(_key), do: {:error, :invalid_idempotency_key}

  defp keyed_idempotency(idempotency_key, grant, opts) do
    verifier = Keyword.get(opts, :verifier, HMACKeyedVerifier)
    key_id = value(grant, :verifier_key_id)
    material = "serviceradar-callback-idempotency-v1\0" <> idempotency_key

    with {:ok, digest} <-
           verifier.digest(key_id, material, Keyword.fetch!(opts, :verifier_config)) do
      {:ok, %{key_id: key_id, verifier: digest}}
    end
  end

  defp snapshot_digest(snapshot) when is_map(snapshot) and map_size(snapshot) > 0,
    do: CanonicalJSON.digest(snapshot)

  defp snapshot_digest(_snapshot), do: {:error, :authorization_snapshot_required}

  defp datetime(%DateTime{} = value), do: {:ok, value}
  defp datetime(_value), do: {:error, :invalid_expiry}

  defp required_id(value, _reason) when is_binary(value) and value != "", do: :ok
  defp required_id(value, _reason) when is_integer(value) and value > 0, do: :ok
  defp required_id(_value, reason), do: {:error, reason}

  defp string_map(map) when is_map(map) do
    Enum.reduce_while(map, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      key = if is_atom(key), do: Atom.to_string(key), else: key

      cond do
        not is_binary(key) -> {:halt, {:error, :map_keys_must_be_strings}}
        Map.has_key?(acc, key) -> {:halt, {:error, {:duplicate_map_key, key}}}
        true -> {:cont, {:ok, Map.put(acc, key, value)}}
      end
    end)
  end

  defp string_map(_map), do: {:error, :object_required}

  defp digest?(value, length) when is_integer(length),
    do: is_binary(value) and byte_size(value) == length and Regex.match?(~r/\A[0-9a-f]+\z/, value)

  defp digest?(value, %Range{} = range),
    do: is_binary(value) and byte_size(value) in range and Regex.match?(~r/\A[0-9a-f]+\z/, value)

  defp secure_equal(left, right)
       when is_binary(left) and is_binary(right) and byte_size(left) == byte_size(right),
       do: :crypto.hash_equals(left, right)

  defp secure_equal(_left, _right), do: false

  defp now(opts), do: Keyword.get(opts, :now, DateTime.utc_now())
  defp store(opts), do: Keyword.fetch!(opts, :store)
  defp store_context(opts), do: Keyword.get(opts, :store_context)

  defp inspect_reason({:job_terminal, status}), do: "job_terminal:#{status}"
  defp inspect_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp inspect_reason(reason) when is_binary(reason), do: reason
  defp inspect_reason(_reason), do: "unspecified"

  defp value(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp value(_map, _key), do: nil
end
