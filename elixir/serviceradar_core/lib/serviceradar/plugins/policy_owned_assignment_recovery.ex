defmodule ServiceRadar.Plugins.PolicyOwnedAssignmentRecovery do
  @moduledoc """
  Public request boundary for policy-owned legacy plugin assignment recovery.

  Callers provide a real current actor and the ID of a disabled, unbound legacy
  assignment. They cannot supply a partition, policy params, package, source
  owner, credential reference, permission snapshot, or background actor.

  Web and API adapters should pass their authenticated `scope:`. This boundary
  rebuilds a minimal current human actor from that scope; callers outside a
  scope (core workers and focused tests) may instead provide an explicit
  `actor:`. A supplied scope always takes precedence over `actor:`.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Events.AuditWriter
  alias ServiceRadar.Identity.CurrentUserAuthority
  alias ServiceRadar.Plugins.PluginAssignment
  alias ServiceRadar.Plugins.PluginPolicyAssignmentRecoveryRequest
  alias ServiceRadar.Plugins.PluginPolicyAssignmentRecoveryWorker
  alias ServiceRadar.Plugins.PolicyOwnedAssignmentRecovery.Authority
  alias ServiceRadar.Plugins.PolicyOwnedAssignmentRecovery.OwnerReference

  @plugin_manage_permission "settings.plugins.manage"
  @request_lookup_actor SystemActor.system(:plugin_policy_assignment_recovery_lookup)
  @audit_action :plugin_policy_assignment_recovery_request
  @audit_resource_type "plugin_policy_assignment_recovery"

  @spec request(String.t(), keyword()) ::
          {:ok, PluginPolicyAssignmentRecoveryRequest.t()} | {:error, term()}
  def request(legacy_assignment_id, opts \\ [])

  def request(legacy_assignment_id, opts)
      when is_binary(legacy_assignment_id) and is_list(opts) do
    result =
      with :ok <- require_confirmation(opts),
           {:ok, actor} <- initiating_actor(opts),
           {:ok, request} <- existing_or_create(legacy_assignment_id, actor) do
        # A web node may intentionally run without Oban. The durable request is
        # still successful there: the core-side dispatcher periodically enqueues
        # any pending request. When this process has Oban, enqueue immediately.
        _ = PluginPolicyAssignmentRecoveryWorker.enqueue(request.id)
        {:ok, request}
      end

    write_request_audit(result, legacy_assignment_id, audit_actor(opts), opts)
    result
  end

  def request(_legacy_assignment_id, opts) do
    result = {:error, :invalid_legacy_assignment_id}
    opts = if is_list(opts), do: opts, else: []
    write_request_audit(result, nil, audit_actor(opts), opts)
    result
  end

  defp initiating_actor(opts) do
    case Keyword.fetch(opts, :scope) do
      {:ok, scope} -> actor_from_scope(scope)
      :error -> explicit_actor(opts)
    end
  end

  defp actor_from_scope(scope) do
    case CurrentUserAuthority.authorize(scope, @plugin_manage_permission) do
      {:ok, %{user: user, permissions: permissions}} ->
        {:ok,
         %{
           id: value(user, :id),
           email: value(user, :email),
           role: value(user, :role),
           principal_type: :human,
           permissions: permissions
         }}

      {:error, :current_authority_denied} ->
        {:error, :current_authority_denied}

      _ ->
        {:error, :initiating_principal_required}
    end
  end

  defp explicit_actor(opts) do
    case Keyword.get(opts, :actor) do
      actor when is_map(actor) -> {:ok, actor}
      _ -> {:error, :initiating_principal_required}
    end
  end

  defp require_confirmation(opts) do
    if Keyword.get(opts, :confirm) == true,
      do: :ok,
      else: {:error, :recovery_confirmation_required}
  end

  defp existing_or_create(legacy_assignment_id, actor) do
    with {:ok, _owner} <- authorize_legacy_recovery(legacy_assignment_id, actor) do
      existing_or_create_authorized(legacy_assignment_id, actor)
    end
  end

  defp existing_or_create_authorized(legacy_assignment_id, actor) do
    case active_requests_for_legacy(legacy_assignment_id) do
      {:ok, [request | _]} ->
        with :ok <- authorize_existing_request(request, actor) do
          {:ok, request}
        end

      {:ok, []} ->
        create_request(legacy_assignment_id, actor)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_request(legacy_assignment_id, actor) do
    result =
      PluginPolicyAssignmentRecoveryRequest
      # `for_create/4` immediately casts inputs and runs the request's
      # authorization/immutability change. Both the confirmation argument and
      # current actor must therefore be present here; setting either only on
      # the already-validated changeset/action is too late for that change.
      |> Ash.Changeset.for_create(
        :request,
        %{
          legacy_assignment_id: legacy_assignment_id,
          confirm: true
        },
        actor: actor
      )
      |> Ash.create(actor: actor)

    case result do
      {:ok, request} ->
        {:ok, request}

      {:error, reason} ->
        # The active-request partial unique index is the final concurrency
        # guard. A concurrent creator can win after our initial read; re-read
        # under the same actor and reuse that durable request instead of
        # surfacing a database uniqueness error to the caller.
        case active_requests_for_legacy(legacy_assignment_id) do
          {:ok, [request | _]} ->
            with :ok <- authorize_existing_request(request, actor) do
              {:ok, request}
            end

          _ ->
            {:error, reason}
        end
    end
  end

  defp active_requests_for_legacy(legacy_assignment_id) do
    PluginPolicyAssignmentRecoveryRequest.active_for_legacy(
      legacy_assignment_id,
      actor: @request_lookup_actor
    )
  end

  # A policy-recovery request table does not itself carry a tenant key. Always
  # authorize the legacy assignment and its current owner before a privileged
  # lookup can reveal whether a durable request exists for that UUID.
  defp authorize_legacy_recovery(legacy_assignment_id, actor) do
    with {:ok, assignment} <- load_legacy_assignment(legacy_assignment_id, actor),
         :ok <- valid_policy_legacy_assignment(assignment),
         {:ok, owner} <- supported_owner(assignment.policy_id),
         {:ok, _principal} <- Authority.authorize_requester(actor, owner) do
      {:ok, owner}
    end
  end

  # An arbitrary historical `policy_id` is not a recoverable owner reference.
  # Keep this public boundary aligned with the read model and return an
  # allowlisted domain error rather than an OwnerReference parser detail.
  defp supported_owner(policy_id) do
    case OwnerReference.parse(policy_id) do
      {:ok, owner} -> {:ok, owner}
      {:error, :invalid_policy_owner} -> {:error, :unsupported_policy_owner}
    end
  end

  defp load_legacy_assignment(legacy_assignment_id, actor)
       when is_binary(legacy_assignment_id) and is_map(actor) do
    case Ash.get(PluginAssignment, legacy_assignment_id, actor: actor) do
      {:ok, nil} -> {:error, :legacy_assignment_unavailable}
      {:ok, assignment} -> {:ok, assignment}
      {:error, _reason} -> {:error, :legacy_assignment_unavailable}
    end
  end

  defp load_legacy_assignment(_legacy_assignment_id, _actor),
    do: {:error, :legacy_assignment_unavailable}

  defp valid_policy_legacy_assignment(assignment) do
    cond do
      assignment.source != :policy ->
        {:error, :legacy_assignment_not_policy_owned}

      assignment.enabled != false ->
        {:error, :legacy_assignment_still_enabled}

      not blank?(assignment.partition_id) ->
        {:error, :legacy_assignment_already_partition_bound}

      blank?(assignment.agent_uid) or blank?(assignment.policy_id) or
          is_nil(assignment.plugin_package_id) ->
        {:error, :legacy_assignment_incomplete}

      true ->
        :ok
    end
  end

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false

  defp authorize_existing_request(request, actor) do
    with {:ok, owner} <- OwnerReference.parse(request.legacy_policy_id),
         {:ok, _principal} <- Authority.authorize_requester(actor, owner) do
      :ok
    end
  end

  # Request auditing is intentionally independent of request persistence: a
  # denial before the legacy row can be safely loaded must still be visible.
  # The event uses only UUID-shaped resource identifiers and allowlisted
  # reason/outcome labels, never Ash/provider error text or policy params.
  defp write_request_audit(result, legacy_assignment_id, actor, opts) do
    details = %{
      recovery_kind: "policy_owned",
      outcome: audit_outcome(result),
      reason: audit_reason(result)
    }

    audit_opts = [
      action: @audit_action,
      resource_type: @audit_resource_type,
      resource_id: audit_resource_id(legacy_assignment_id),
      resource_name: "policy_owned",
      actor: actor,
      details: details,
      severity: audit_severity(result),
      message: "Policy-owned plugin assignment recovery request #{audit_outcome(result)}"
    ]

    case Keyword.get(opts, :audit_writer, AuditWriter) do
      {writer, writer_opts} -> writer.write_async(Keyword.merge(audit_opts, writer_opts))
      writer -> writer.write_async(audit_opts)
    end

    :ok
  rescue
    _ -> :ok
  end

  defp audit_outcome({:ok, _request}), do: "accepted"
  defp audit_outcome({:error, _reason}), do: "denied"
  defp audit_outcome(_result), do: "denied"

  defp audit_reason({:ok, _request}), do: "request_accepted"

  defp audit_reason({:error, reason}) do
    case reason do
      :recovery_confirmation_required -> "confirmation_required"
      :invalid_legacy_assignment_id -> "invalid_assignment_id"
      :initiating_principal_required -> "initiating_principal_required"
      :current_authority_denied -> "current_authority_denied"
      :current_permission_denied -> "current_permission_denied"
      :unsupported_policy_owner -> "unsupported_policy_owner"
      :owner_not_found -> "owner_not_found"
      :owner_not_authoritative -> "owner_not_authoritative"
      :principal_disabled -> "principal_disabled"
      :principal_not_found -> "principal_not_found"
      :record_not_found -> "principal_not_found"
      :principal_owner_changed -> "principal_owner_changed"
      :service_principal_write_scope_required -> "service_principal_write_scope_required"
      _ -> "request_rejected"
    end
  end

  defp audit_reason(_result), do: "request_rejected"

  defp audit_severity({:ok, _request}), do: :medium
  defp audit_severity(_result), do: :high

  defp audit_resource_id(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, id} -> id
      :error -> "unknown"
    end
  end

  defp audit_resource_id(_value), do: "unknown"

  defp audit_actor(opts) do
    opts
    |> initiating_audit_subject()
    |> case do
      subject when is_map(subject) ->
        %{
          id: value(subject, :id),
          email: value(subject, :email),
          role: value(subject, :role),
          principal_type: value(subject, :principal_type)
        }

      _ ->
        nil
    end
  end

  defp initiating_audit_subject(opts) do
    case Keyword.get(opts, :scope) do
      scope when is_map(scope) -> value(scope, :user)
      _ -> Keyword.get(opts, :actor)
    end
  end

  defp value(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp value(_map, _key), do: nil
end
