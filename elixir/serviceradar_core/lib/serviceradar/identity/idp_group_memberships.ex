defmodule ServiceRadar.Identity.IdpGroupMemberships do
  @moduledoc """
  Reconciles a user's identity-provider-sourced group memberships at sign-in.

  Group memberships back access grants -- dashboard sharing, device group grants
  -- and were previously maintained entirely by hand, so an IdP group and the
  ServiceRadar group of the same name were two unrelated lists that drifted.

  Reconciliation is deliberately narrow: it adds memberships for the groups a
  user's claims currently map to, and withdraws only those it previously added
  itself. A membership an operator created is never touched, because the
  identity provider knows nothing about it and "the claim did not arrive" is not
  evidence that an operator's decision was wrong.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.UserGroupMembership

  require Logger

  @type result :: %{added: [String.t()], withdrawn: [String.t()], kept: [String.t()]}

  @doc """
  Makes the user's IdP-sourced memberships match `group_ids`.

  Returns which memberships were added, withdrawn, and left alone. Errors on
  individual rows are logged and skipped rather than raised: a sign-in must not
  fail because one group could not be reconciled, and the caller has already
  applied the role and profile by this point.
  """
  @spec sync(String.t(), [String.t()], keyword()) :: result()
  def sync(user_id, group_ids, opts \\ [])

  def sync(user_id, group_ids, opts) when is_binary(user_id) and is_list(group_ids) do
    actor = Keyword.get(opts, :actor) || SystemActor.system(:idp_group_membership_sync)
    desired = MapSet.new(group_ids)
    existing = list_memberships(user_id, actor)

    existing_idp =
      existing
      |> Enum.filter(&(&1.source == :idp))
      |> Map.new(&{&1.group_id, &1})

    # A group the operator already added by hand needs no IdP row, and must not
    # be converted into one -- that would make it withdrawable.
    manual_group_ids =
      existing
      |> Enum.filter(&(&1.source == :manual))
      |> MapSet.new(& &1.group_id)

    to_add =
      desired
      |> MapSet.difference(MapSet.new(Map.keys(existing_idp)))
      |> MapSet.difference(manual_group_ids)
      |> MapSet.to_list()

    to_withdraw =
      existing_idp
      |> Map.keys()
      |> Enum.reject(&MapSet.member?(desired, &1))

    added = Enum.filter(to_add, &add_membership(user_id, &1, actor))
    withdrawn = Enum.filter(to_withdraw, &withdraw_membership(existing_idp[&1], actor))

    %{
      added: added,
      withdrawn: withdrawn,
      kept: MapSet.to_list(MapSet.intersection(desired, manual_group_ids))
    }
  end

  def sync(_user_id, _group_ids, _opts), do: %{added: [], withdrawn: [], kept: []}

  defp list_memberships(user_id, actor) do
    case UserGroupMembership.list_by_user(user_id, actor: actor) do
      {:ok, memberships} ->
        memberships

      {:error, reason} ->
        Logger.warning("Could not read group memberships for user #{user_id}: #{inspect(reason)}")
        []
    end
  end

  defp add_membership(user_id, group_id, actor) do
    attrs = %{user_id: user_id, group_id: group_id, source: :idp}

    case UserGroupMembership.create_membership(attrs, actor: actor) do
      {:ok, _membership} ->
        true

      {:error, reason} ->
        # A mapping naming a group that no longer exists should not fail the
        # sign-in; it grants nothing, which is the safe direction.
        Logger.warning(
          "Could not add IdP group membership user=#{user_id} group=#{group_id}: #{inspect(reason)}"
        )

        false
    end
  end

  defp withdraw_membership(nil, _actor), do: false

  defp withdraw_membership(membership, actor) do
    case Ash.destroy(membership, actor: actor) do
      :ok ->
        true

      {:ok, _record} ->
        true

      {:error, reason} ->
        Logger.warning(
          "Could not withdraw IdP group membership #{membership.id}: #{inspect(reason)}"
        )

        false
    end
  end
end
