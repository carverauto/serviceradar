defmodule ServiceRadar.Plugins.Changes.PreparePolicyAssignmentRecoveryRequest do
  @moduledoc false

  use Ash.Resource.Change

  alias ServiceRadar.AshContext
  alias ServiceRadar.Plugins.PluginAssignment
  alias ServiceRadar.Plugins.PolicyOwnedAssignmentRecovery.Authority
  alias ServiceRadar.Plugins.PolicyOwnedAssignmentRecovery.OwnerReference

  @impl true
  def change(changeset, _opts, context) do
    actor = AshContext.actor(changeset) || AshContext.actor(context)
    legacy_assignment_id = Ash.Changeset.get_attribute(changeset, :legacy_assignment_id)
    confirmed? = Ash.Changeset.get_argument(changeset, :confirm) == true

    with true <- confirmed? || {:error, :recovery_confirmation_required},
         {:ok, assignment} <- legacy_assignment(legacy_assignment_id, actor),
         :ok <- valid_legacy_assignment(assignment),
         {:ok, owner} <- supported_owner(assignment.policy_id),
         {:ok, requester} <- Authority.authorize_requester(actor, owner) do
      stamp_immutable_request(changeset, assignment, owner, requester)
    else
      {:error, reason} -> invalid_request(changeset, reason)
      _ -> invalid_request(changeset, :legacy_assignment_unavailable)
    end
  end

  defp legacy_assignment(legacy_assignment_id, actor)
       when is_binary(legacy_assignment_id) and is_map(actor) do
    case Ash.get(PluginAssignment, legacy_assignment_id, actor: actor) do
      {:ok, nil} -> {:error, :legacy_assignment_unavailable}
      {:ok, assignment} -> {:ok, assignment}
      {:error, _reason} -> {:error, :legacy_assignment_unavailable}
    end
  end

  defp legacy_assignment(_legacy_assignment_id, _actor),
    do: {:error, :legacy_assignment_unavailable}

  defp valid_legacy_assignment(assignment) do
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

  defp supported_owner(policy_id) do
    case OwnerReference.parse(policy_id) do
      {:ok, owner} -> {:ok, owner}
      {:error, :invalid_policy_owner} -> {:error, :unsupported_policy_owner}
    end
  end

  defp stamp_immutable_request(changeset, assignment, owner, requester) do
    identity = requester.identity

    changeset
    |> force(:legacy_assignment_id, assignment.id)
    |> force(:legacy_agent_uid, assignment.agent_uid)
    |> force(:legacy_policy_id, assignment.policy_id)
    |> force(:legacy_plugin_package_id, assignment.plugin_package_id)
    |> force(:owner_kind, owner.kind)
    |> force(:owner_id, owner.id)
    |> force(:owner_purpose, owner.purpose)
    |> force(:requested_by_principal_type, identity.principal_type)
    |> force(:requested_by_principal_id, identity.principal_id)
    |> force(:requested_by_principal_owner_id, identity.principal_owner_id)
    |> force(:status, :requested)
  end

  defp invalid_request(changeset, reason) do
    Ash.Changeset.add_error(changeset,
      field: :legacy_assignment_id,
      message: message_for(reason)
    )
  end

  defp force(changeset, _attribute, nil), do: changeset

  defp force(changeset, attribute, value),
    do: Ash.Changeset.force_change_attribute(changeset, attribute, value)

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false

  defp message_for(:legacy_assignment_not_policy_owned), do: "assignment is not policy owned"

  defp message_for(:legacy_assignment_still_enabled),
    do: "assignment is not a legacy recovery row"

  defp message_for(:legacy_assignment_already_partition_bound),
    do: "assignment is already partition bound"

  defp message_for(:legacy_assignment_incomplete), do: "assignment cannot be recovered"
  defp message_for(:recovery_confirmation_required), do: "recovery confirmation is required"

  defp message_for(:unsupported_policy_owner),
    do: "assignment has an unsupported historical policy owner"

  defp message_for(:current_permission_denied), do: "current permissions do not allow recovery"
  defp message_for(:owner_not_found), do: "current policy owner is unavailable"
  defp message_for(:principal_disabled), do: "initiating principal is no longer active"

  defp message_for(:initiating_principal_required),
    do: "an active initiating principal is required"

  defp message_for(_reason), do: "assignment recovery is not currently authorized"
end
