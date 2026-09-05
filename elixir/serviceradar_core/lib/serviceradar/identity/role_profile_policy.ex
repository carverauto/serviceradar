defmodule ServiceRadar.Identity.RoleProfilePolicy do
  @moduledoc """
  Transaction boundary for custom role-profile lifecycle mutations.

  Human authority is reconstructed from persistence before each mutation. The
  boundary owns the database transaction and publishes targeted user-cache and
  audit effects only after it commits.
  """

  import Ecto.Query, only: [from: 2]

  alias ServiceRadar.Identity.PrivilegeMutationEffects
  alias ServiceRadar.Identity.RoleProfile
  alias ServiceRadar.Identity.User
  alias ServiceRadar.Identity.UserGroup
  alias ServiceRadar.Repo

  require Ash.Query

  @permission "settings.rbac.manage"
  @boundary_context %{privilege_boundary_owned: true}

  @spec create(map(), map(), keyword()) :: {:ok, RoleProfile.t()} | {:error, term()}
  def create(scope, attrs, opts \\ [])

  def create(scope, attrs, opts) do
    if Repo.in_transaction?() do
      {:error, :outer_transaction_not_supported}
    else
      do_create(scope, attrs, opts)
    end
  end

  defp do_create(scope, attrs, opts) when is_map(attrs) and is_list(opts) do
    PrivilegeMutationEffects.run(
      scope,
      @permission,
      fn actor -> create_in_transaction(actor, attrs) end,
      opts
    )
  end

  defp do_create(_scope, _attrs, _opts), do: {:error, :invalid_attributes}

  @spec update(map(), String.t(), map(), keyword()) ::
          {:ok, RoleProfile.t()} | {:error, term()}
  def update(scope, profile_id, attrs, opts \\ [])

  def update(scope, profile_id, attrs, opts) do
    if Repo.in_transaction?() do
      {:error, :outer_transaction_not_supported}
    else
      do_update(scope, profile_id, attrs, opts)
    end
  end

  defp do_update(scope, profile_id, attrs, opts)
       when is_binary(profile_id) and is_map(attrs) and is_list(opts) do
    PrivilegeMutationEffects.run(
      scope,
      @permission,
      fn actor -> update_in_transaction(actor, profile_id, attrs) end,
      opts
    )
  end

  defp do_update(_scope, _profile_id, _attrs, _opts), do: {:error, :invalid_attributes}

  @spec delete(map(), String.t(), keyword()) :: {:ok, RoleProfile.t()} | {:error, term()}
  def delete(scope, profile_id, opts \\ [])

  def delete(scope, profile_id, opts) do
    if Repo.in_transaction?() do
      {:error, :outer_transaction_not_supported}
    else
      do_delete(scope, profile_id, opts)
    end
  end

  defp do_delete(scope, profile_id, opts) when is_binary(profile_id) and is_list(opts) do
    PrivilegeMutationEffects.run(
      scope,
      @permission,
      fn actor -> delete_in_transaction(actor, profile_id, opts) end,
      opts
    )
  end

  defp do_delete(_scope, _profile_id, _opts), do: {:error, :invalid_attributes}

  defp create_in_transaction(actor, attrs) do
    RoleProfile
    |> Ash.Changeset.for_create(:create, attrs, actor: actor, context: @boundary_context)
    |> Ash.create(actor: actor)
    |> case do
      {:ok, profile} -> {:ok, profile, [], audit_options(:create, profile, actor)}
      {:error, _reason} = error -> error
    end
  end

  defp update_in_transaction(actor, profile_id, attrs) do
    with {:ok, profile} <- lock_custom_profile(profile_id, actor),
         {:ok, affected_ids} <- affected_user_ids(profile.id, actor),
         {:ok, updated} <- update_profile(profile, attrs, actor) do
      {:ok, updated, affected_ids, audit_options(:update, updated, actor)}
    end
  end

  defp delete_in_transaction(actor, profile_id, opts) do
    with {:ok, profile} <- lock_custom_profile(profile_id, actor),
         {:ok, direct_users, groups, affected_ids} <- affected_assignments(profile.id, actor),
         :ok <- clear_assignments(direct_users, actor),
         :ok <- clear_assignments(groups, actor),
         :ok <- after_references_cleared(opts),
         :ok <- destroy_profile(profile, actor) do
      {:ok, profile, affected_ids, audit_options(:delete, profile, actor)}
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp lock_custom_profile(profile_id, actor) do
    RoleProfile
    |> Ash.Query.for_read(:get_by_id, %{id: profile_id}, actor: actor)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one(actor: actor)
    |> case do
      {:ok, nil} -> {:error, :role_profile_not_found}
      {:ok, %RoleProfile{system: true}} -> {:error, :system_profile_not_mutable}
      result -> result
    end
  end

  defp affected_user_ids(profile_id, actor) do
    with {:ok, _direct_users, _groups, affected_ids} <- affected_assignments(profile_id, actor) do
      {:ok, affected_ids}
    end
  end

  defp affected_assignments(profile_id, actor) do
    with {:ok, direct_users} <- direct_assignees(profile_id),
         {:ok, groups} <- referencing_groups(profile_id, actor),
         {:ok, group_user_ids} <- group_member_ids(groups) do
      {:ok, direct_users, groups, Enum.map(direct_users, & &1.id) ++ group_user_ids}
    end
  end

  defp direct_assignees(profile_id) do
    # The boundary has already reconstructed and authorized the human actor.
    # Load and lock every FK reference directly so record-level read filters
    # cannot omit a user that must be coordinated before profile deletion.
    users =
      from(user in {"ng_users", User}, where: user.role_profile_id == ^profile_id)
      |> Ecto.Query.lock("FOR UPDATE")
      |> Repo.all(prefix: "platform")

    {:ok, users}
  end

  defp referencing_groups(profile_id, actor) do
    UserGroup
    |> Ash.Query.for_read(:for_role_profile_boundary, %{role_profile_id: profile_id},
      actor: actor
    )
    |> Ash.read(actor: actor)
  end

  defp group_member_ids([]), do: {:ok, []}

  defp group_member_ids(groups) do
    group_ids = Enum.map(groups, & &1.id)
    group_id_params = Enum.map(group_ids, &Ecto.UUID.dump!/1)

    placeholders =
      group_ids
      |> Enum.with_index(1)
      |> Enum.map_join(", ", fn {_id, index} -> "$#{index}::uuid" end)

    query = """
    SELECT user_id::text
    FROM platform.user_group_memberships
    WHERE group_id IN (#{placeholders})
    """

    case Repo.query(query, group_id_params) do
      {:ok, %{rows: rows}} -> {:ok, Enum.map(rows, fn [user_id] -> user_id end)}
      {:error, _reason} = error -> error
    end
  end

  defp update_profile(profile, attrs, actor) do
    profile
    |> Ash.Changeset.for_update(:update, attrs, actor: actor, context: @boundary_context)
    |> Ash.update(actor: actor)
  end

  defp clear_assignments(records, actor) do
    Enum.reduce_while(records, :ok, fn record, :ok ->
      record
      |> Ash.Changeset.for_update(:clear_role_profile_for_boundary, %{},
        actor: actor,
        context: @boundary_context
      )
      |> Ash.update(actor: actor)
      |> case do
        {:ok, _updated} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:clear_assignment_failed, reason}}}
      end
    end)
  end

  defp after_references_cleared(opts) do
    case Keyword.get(opts, :after_references_cleared) do
      nil -> :ok
      callback when is_function(callback, 0) -> callback.()
      _other -> {:error, :invalid_after_references_cleared}
    end
  end

  defp destroy_profile(profile, actor) do
    profile
    |> Ash.Changeset.for_destroy(:destroy, %{}, actor: actor, context: @boundary_context)
    |> Ash.destroy(actor: actor)
  end

  defp audit_options(action, profile, actor) do
    [
      action: action,
      resource_type: "role_profile",
      resource_id: profile.id,
      resource_name: profile.name,
      actor: actor,
      details: %{system: profile.system}
    ]
  end
end
