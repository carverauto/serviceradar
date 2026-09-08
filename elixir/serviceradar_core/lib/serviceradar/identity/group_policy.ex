defmodule ServiceRadar.Identity.GroupPolicy do
  @moduledoc """
  Transaction boundary for role-profile assignment and deletion of user groups.
  """

  alias ServiceRadar.Identity.PrivilegeMutationEffects
  alias ServiceRadar.Identity.RoleProfile
  alias ServiceRadar.Identity.UserGroup
  alias ServiceRadar.Identity.UserGroupMembership
  alias ServiceRadar.Repo

  require Ash.Query

  @permissions ["settings.rbac.manage", "identity.user_groups.manage"]
  @boundary_context %{privilege_boundary_owned: true}

  @spec assign(map(), String.t(), String.t(), keyword()) ::
          {:ok, UserGroup.t()} | {:error, term()}
  def assign(scope, group_id, profile_id, opts \\ [])

  def assign(scope, group_id, profile_id, opts) do
    if Repo.in_transaction?() do
      {:error, :outer_transaction_not_supported}
    else
      do_assign(scope, group_id, profile_id, opts)
    end
  end

  defp do_assign(scope, group_id, profile_id, opts)
       when is_binary(group_id) and is_binary(profile_id) and is_list(opts) do
    PrivilegeMutationEffects.run(
      scope,
      @permissions,
      fn actor -> assign_in_transaction(actor, group_id, profile_id) end,
      opts
    )
  end

  defp do_assign(_scope, _group_id, _profile_id, _opts), do: {:error, :invalid_attributes}

  @spec clear(map(), String.t(), keyword()) :: {:ok, UserGroup.t()} | {:error, term()}
  def clear(scope, group_id, opts \\ [])

  def clear(scope, group_id, opts) do
    if Repo.in_transaction?() do
      {:error, :outer_transaction_not_supported}
    else
      do_clear(scope, group_id, opts)
    end
  end

  defp do_clear(scope, group_id, opts) when is_binary(group_id) and is_list(opts) do
    PrivilegeMutationEffects.run(
      scope,
      @permissions,
      fn actor -> clear_in_transaction(actor, group_id) end,
      opts
    )
  end

  defp do_clear(_scope, _group_id, _opts), do: {:error, :invalid_attributes}

  @spec delete(map(), String.t(), keyword()) :: {:ok, UserGroup.t()} | {:error, term()}
  def delete(scope, group_id, opts \\ [])

  def delete(scope, group_id, opts) do
    if Repo.in_transaction?() do
      {:error, :outer_transaction_not_supported}
    else
      do_delete(scope, group_id, opts)
    end
  end

  defp do_delete(scope, group_id, opts) when is_binary(group_id) and is_list(opts) do
    PrivilegeMutationEffects.run(
      scope,
      @permissions,
      fn actor -> delete_in_transaction(actor, group_id) end,
      opts
    )
  end

  defp do_delete(_scope, _group_id, _opts), do: {:error, :invalid_attributes}

  defp assign_in_transaction(actor, group_id, profile_id) do
    with {:ok, group} <- locked_group(actor, group_id),
         {:ok, %RoleProfile{}} <- RoleProfile.get_by_id(profile_id, actor: actor),
         {:ok, user_ids} <- member_ids(actor, group_id),
         {:ok, updated_group} <- update_group(actor, group, :assign_role_profile, profile_id) do
      {:ok, updated_group, user_ids,
       audit_opts(
         :assign_role_profile,
         updated_group,
         actor,
         %{from_role_profile_id: group.role_profile_id, to_role_profile_id: profile_id}
       )}
    end
  end

  defp clear_in_transaction(actor, group_id) do
    with {:ok, group} <- locked_group(actor, group_id),
         {:ok, user_ids} <- member_ids(actor, group_id),
         {:ok, updated_group} <- update_group(actor, group, :clear_role_profile, nil) do
      {:ok, updated_group, user_ids,
       audit_opts(
         :clear_role_profile,
         updated_group,
         actor,
         %{from_role_profile_id: group.role_profile_id, to_role_profile_id: nil}
       )}
    end
  end

  defp delete_in_transaction(actor, group_id) do
    with {:ok, group} <- locked_group(actor, group_id),
         {:ok, user_ids} <- member_ids(actor, group_id),
         {:ok, deleted_group} <- destroy_group(actor, group) do
      {:ok, deleted_group, user_ids, audit_opts(:delete, deleted_group, actor, %{})}
    end
  end

  defp locked_group(actor, group_id) do
    UserGroup
    |> Ash.Query.for_read(:for_privilege_boundary, %{id: group_id}, actor: actor)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one(actor: actor)
    |> require_record(:group_not_found)
  end

  defp member_ids(actor, group_id) do
    UserGroupMembership
    |> Ash.Query.for_read(:for_group_privilege_boundary, %{group_id: group_id}, actor: actor)
    |> Ash.read(actor: actor)
    |> case do
      {:ok, memberships} -> {:ok, Enum.map(memberships, & &1.user_id)}
      {:error, _reason} = error -> error
    end
  end

  defp update_group(actor, group, action, profile_id) do
    attrs = if action == :assign_role_profile, do: %{role_profile_id: profile_id}, else: %{}

    group
    |> Ash.Changeset.for_update(action, attrs, actor: actor, context: @boundary_context)
    |> Ash.update(actor: actor)
  end

  defp destroy_group(actor, group) do
    group
    |> Ash.Changeset.for_destroy(:destroy, %{}, actor: actor, context: @boundary_context)
    |> Ash.destroy(actor: actor, return_destroyed?: true)
  end

  defp require_record({:ok, nil}, reason), do: {:error, reason}
  defp require_record(result, _reason), do: result

  defp audit_opts(action, group, actor, details) do
    [
      action: action,
      resource_type: "user_group",
      resource_id: group.id,
      resource_name: group.name,
      actor: actor,
      details: details
    ]
  end
end
