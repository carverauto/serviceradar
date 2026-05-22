defmodule ServiceRadar.Dashboards.Checks.ActorCanAccessDashboard do
  @moduledoc """
  Filters authored dashboards to records visible to the current actor.
  """

  use Ash.Policy.FilterCheck

  import Ash.Expr

  @impl true
  def describe(_opts), do: "actor can access authored dashboard"

  @impl true
  def filter(%{id: actor_id, role: :system}, _authorizer, _opts) when not is_nil(actor_id) do
    expr(true)
  end

  def filter(%{id: actor_id}, _authorizer, _opts) when not is_nil(actor_id) do
    expr(
      owner_id == ^actor_id or
        visibility == :public or
        exists(
          access_grants,
          access in [:view, :edit] and
            ((subject_type == :user and subject_user_id == ^actor_id) or
               (subject_type == :group and exists(subject_group.memberships, user_id == ^actor_id)))
        )
    )
  end

  def filter(_actor, _authorizer, _opts), do: expr(visibility == :public)
end
