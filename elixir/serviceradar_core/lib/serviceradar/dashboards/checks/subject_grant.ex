defmodule ServiceRadar.Dashboards.Checks.SubjectGrant do
  @moduledoc """
  Single grant-matching predicate for authored and package dashboard access.

  Filter-check expressions and the in-memory matcher for create/update SimpleChecks
  all live here so authored and package paths cannot drift.
  """

  import Ash.Expr

  def authored_access(actor_id) do
    expr(
      owner_id == ^actor_id or
        visibility == :public or
        exists(
          access_grants,
          access in [:view, :edit] and
            ((subject_type == :user and subject_user_id == ^actor_id) or
               (subject_type == :group and
                  exists(subject_group.memberships, user_id == ^actor_id)))
        )
    )
  end

  def authored_edit(actor_id) do
    expr(
      owner_id == ^actor_id or
        exists(
          access_grants,
          access == :edit and
            ((subject_type == :user and subject_user_id == ^actor_id) or
               (subject_type == :group and
                  exists(subject_group.memberships, user_id == ^actor_id)))
        )
    )
  end

  def parent_dashboard_access(actor_id) do
    expr(
      dashboard.owner_id == ^actor_id or
        dashboard.visibility == :public or
        exists(
          dashboard.access_grants,
          access in [:view, :edit] and
            ((subject_type == :user and subject_user_id == ^actor_id) or
               (subject_type == :group and
                  exists(subject_group.memberships, user_id == ^actor_id)))
        )
    )
  end

  def parent_dashboard_edit(actor_id) do
    expr(
      dashboard.owner_id == ^actor_id or
        exists(
          dashboard.access_grants,
          access == :edit and
            ((subject_type == :user and subject_user_id == ^actor_id) or
               (subject_type == :group and
                  exists(subject_group.memberships, user_id == ^actor_id)))
        )
    )
  end

  def instance_access(actor_id) do
    expr(
      owner_id == ^actor_id or
        visibility == :public or
        (visibility == :shared and
           exists(
             access_grants,
             access in [:view, :edit] and
               ((subject_type == :user and subject_user_id == ^actor_id) or
                  (subject_type == :group and
                     exists(subject_group.memberships, user_id == ^actor_id)))
           ))
    )
  end

  def parent_instance_edit(actor_id) do
    expr(
      dashboard_instance.owner_id == ^actor_id or
        exists(
          dashboard_instance.access_grants,
          access == :edit and
            ((subject_type == :user and subject_user_id == ^actor_id) or
               (subject_type == :group and
                  exists(subject_group.memberships, user_id == ^actor_id)))
        )
    )
  end

  def instance_edit(actor_id) do
    expr(
      owner_id == ^actor_id or
        exists(
          access_grants,
          access == :edit and
            ((subject_type == :user and subject_user_id == ^actor_id) or
               (subject_type == :group and
                  exists(subject_group.memberships, user_id == ^actor_id)))
        )
    )
  end

  def matches_actor?(grant, actor_id) when not is_nil(actor_id) do
    actor_id = to_string(actor_id)

    cond do
      grant_subject_type(grant) in [:user, "user"] ->
        grant |> grant_user_id() |> stringify() == actor_id

      grant_subject_type(grant) in [:group, "group"] ->
        grant
        |> grant_group_memberships()
        |> Enum.any?(&(to_string(&1.user_id) == actor_id))

      true ->
        false
    end
  end

  def matches_actor?(_grant, _actor_id), do: false

  defp grant_subject_type(%{subject_type: type}), do: type
  defp grant_subject_type(_), do: nil

  defp grant_user_id(%{subject_user_id: id}), do: id
  defp grant_user_id(_), do: nil

  defp grant_group_memberships(%{subject_group: %{memberships: memberships}})
       when is_list(memberships), do: memberships

  defp grant_group_memberships(_), do: []

  defp stringify(nil), do: nil
  defp stringify(value), do: to_string(value)
end
