defmodule ServiceRadar.Identity.PrivilegedMembership do
  @moduledoc """
  Transaction boundary for privilege-bearing user-group memberships.

  Human changes reconstruct current authority. IdP reconciliation is the one
  trusted system path; each independent row owns its own transaction so one
  stale mapping cannot block sign-in or successful mappings.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.PrivilegeMutationEffects
  alias ServiceRadar.Identity.UserGroupMembership
  alias ServiceRadar.Repo

  require Ash.Expr
  require Ash.Query
  require Logger

  @permission "identity.user_groups.manage"
  @boundary_context %{privilege_boundary_owned: true}
  @empty_result %{added: [], withdrawn: [], kept: []}

  @type reconcile_result :: %{added: [String.t()], withdrawn: [String.t()], kept: [String.t()]}

  @spec add(map(), String.t(), String.t(), map(), keyword()) ::
          {:ok, UserGroupMembership.t()} | {:error, term()}
  def add(scope, group_id, user_id, attrs \\ %{}, opts \\ [])

  def add(scope, group_id, user_id, attrs, opts) do
    if Repo.in_transaction?() do
      {:error, :outer_transaction_not_supported}
    else
      do_add(scope, group_id, user_id, attrs, opts)
    end
  end

  defp do_add(scope, group_id, user_id, attrs, opts)
       when is_binary(group_id) and is_binary(user_id) and is_map(attrs) and is_list(opts) do
    membership_attrs =
      attrs
      |> Map.take([:role, :metadata])
      |> Map.merge(%{group_id: group_id, user_id: user_id})

    PrivilegeMutationEffects.run(
      scope,
      @permission,
      fn actor -> create_manual(actor, membership_attrs) end,
      opts
    )
  end

  defp do_add(_scope, _group_id, _user_id, _attrs, _opts), do: {:error, :invalid_attributes}

  @spec remove(map(), String.t(), keyword()) ::
          {:ok, UserGroupMembership.t()} | {:error, term()}
  def remove(scope, membership_id, opts \\ [])

  def remove(scope, membership_id, opts) do
    if Repo.in_transaction?() do
      {:error, :outer_transaction_not_supported}
    else
      do_remove(scope, membership_id, opts)
    end
  end

  defp do_remove(scope, membership_id, opts) when is_binary(membership_id) and is_list(opts) do
    PrivilegeMutationEffects.run(
      scope,
      @permission,
      fn actor -> remove_manual(actor, membership_id) end,
      opts
    )
  end

  defp do_remove(_scope, _membership_id, _opts), do: {:error, :invalid_attributes}

  @doc """
  Reconciles only IdP-owned memberships, best effort per group mapping.

  A persisted manual row always wins. Conditional database predicates protect
  both insertion and withdrawal when a concurrent operator changes ownership.
  """
  @spec reconcile_idp(String.t(), [String.t()], keyword()) ::
          reconcile_result() | {:error, :outer_transaction_not_supported}
  def reconcile_idp(user_id, group_ids, opts \\ [])

  def reconcile_idp(user_id, group_ids, opts) do
    if Repo.in_transaction?() do
      {:error, :outer_transaction_not_supported}
    else
      validate_reconcile_idp(user_id, group_ids, opts)
    end
  end

  defp validate_reconcile_idp(user_id, group_ids, opts)
       when is_binary(user_id) and is_list(group_ids) and is_list(opts),
       do: do_reconcile_idp(user_id, group_ids, opts)

  defp validate_reconcile_idp(_user_id, _group_ids, _opts), do: @empty_result

  defp create_manual(actor, attrs) do
    UserGroupMembership
    |> Ash.Changeset.for_create(:create_manual, attrs,
      actor: actor,
      context: @boundary_context
    )
    |> Ash.create(actor: actor)
    |> case do
      {:ok, membership} ->
        {:ok, membership, [membership.user_id], audit_opts(:add_member, membership, actor)}

      {:error, _reason} = error ->
        error
    end
  end

  defp remove_manual(actor, membership_id) do
    with {:ok, membership} <- locked_membership(actor, membership_id),
         {:ok, deleted} <- destroy_membership(actor, membership) do
      {:ok, deleted, [deleted.user_id], audit_opts(:remove_member, deleted, actor)}
    end
  end

  defp do_reconcile_idp(user_id, group_ids, opts) do
    actor = Keyword.get(opts, :actor, SystemActor.system(:idp_group_membership_sync))

    if SystemActor.system_actor?(actor) do
      desired = group_ids |> Enum.filter(&is_binary/1) |> MapSet.new()
      existing = list_memberships(user_id, actor)

      existing_idp =
        existing
        |> Enum.filter(&(&1.source == :idp))
        |> Map.new(&{&1.group_id, &1})

      manual_group_ids =
        existing
        |> Enum.filter(&(&1.source == :manual))
        |> MapSet.new(& &1.group_id)

      to_add =
        desired
        |> MapSet.difference(MapSet.new(Map.keys(existing_idp)))
        |> Enum.sort()

      to_withdraw =
        existing_idp
        |> Map.keys()
        |> Enum.reject(&MapSet.member?(desired, &1))
        |> Enum.sort()

      added = Enum.filter(to_add, &add_idp_membership(user_id, &1, actor, opts))

      withdrawn =
        Enum.filter(to_withdraw, &withdraw_idp_membership(existing_idp[&1], actor, opts))

      %{
        added: added,
        withdrawn: withdrawn,
        kept: desired |> MapSet.intersection(manual_group_ids) |> Enum.sort()
      }
    else
      Logger.warning("IdP membership reconciliation requires a trusted system actor")
      @empty_result
    end
  end

  defp list_memberships(user_id, actor) do
    case UserGroupMembership.list_by_user(user_id, actor: actor) do
      {:ok, memberships} ->
        memberships

      {:error, reason} ->
        Logger.warning("Could not read group memberships for user #{user_id}: #{inspect(reason)}")
        []
    end
  end

  defp add_idp_membership(user_id, group_id, actor, opts) do
    result =
      PrivilegeMutationEffects.run_system(
        actor,
        fn transaction_actor -> create_idp(transaction_actor, user_id, group_id) end,
        opts
      )

    case result do
      {:ok, :added} ->
        true

      {:ok, :skipped} ->
        false

      {:error, reason} ->
        Logger.warning(
          "Could not add IdP group membership user=#{user_id} group=#{group_id}: #{inspect(reason)}"
        )

        false
    end
  end

  defp create_idp(actor, user_id, group_id) do
    UserGroupMembership
    |> Ash.Changeset.for_create(
      :create_idp,
      %{user_id: user_id, group_id: group_id, metadata: %{}},
      actor: actor,
      context: @boundary_context
    )
    |> Ash.create(actor: actor)
    |> case do
      {:ok, membership} ->
        if Ash.Resource.get_metadata(membership, :upsert_skipped) == true do
          {:ok, :skipped, [], []}
        else
          {:ok, :added, [user_id], audit_opts(:add_idp_member, membership, actor)}
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp withdraw_idp_membership(nil, _actor, _opts), do: false

  defp withdraw_idp_membership(membership, actor, opts) do
    result =
      PrivilegeMutationEffects.run_system(
        actor,
        fn transaction_actor -> withdraw_idp(transaction_actor, membership.id) end,
        opts
      )

    case result do
      {:ok, :withdrawn} ->
        true

      {:error, reason} ->
        Logger.warning(
          "Could not withdraw IdP group membership #{membership.id}: #{inspect(reason)}"
        )

        false
    end
  end

  defp withdraw_idp(actor, membership_id) do
    with {:ok, membership} <- locked_membership(actor, membership_id),
         {:ok, deleted} <- destroy_idp_membership(actor, membership) do
      {:ok, :withdrawn, [deleted.user_id], audit_opts(:withdraw_idp_member, deleted, actor)}
    end
  end

  defp locked_membership(actor, membership_id) do
    UserGroupMembership
    |> Ash.Query.for_read(
      :for_membership_privilege_boundary,
      %{id: membership_id},
      actor: actor
    )
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one(actor: actor)
    |> case do
      {:ok, nil} -> {:error, :membership_not_found}
      result -> result
    end
  end

  defp destroy_membership(actor, membership) do
    membership
    |> Ash.Changeset.for_destroy(:destroy, %{}, actor: actor, context: @boundary_context)
    |> Ash.destroy(actor: actor, return_destroyed?: true)
  end

  defp destroy_idp_membership(actor, membership) do
    membership
    |> Ash.Changeset.for_destroy(:destroy, %{}, actor: actor, context: @boundary_context)
    |> Ash.Changeset.filter(Ash.Expr.expr(source == :idp))
    |> Ash.destroy(actor: actor, return_destroyed?: true)
  end

  defp audit_opts(action, membership, actor) do
    [
      action: action,
      resource_type: "user_group_membership",
      resource_id: membership.id,
      actor: actor,
      details: %{group_id: membership.group_id, user_id: membership.user_id}
    ]
  end
end
