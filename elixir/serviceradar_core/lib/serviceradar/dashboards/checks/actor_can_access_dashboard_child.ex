defmodule ServiceRadar.Dashboards.Checks.ActorCanAccessDashboardChild do
  @moduledoc """
  Filters child dashboard resources through their parent authored dashboard.
  """

  use Ash.Policy.FilterCheck

  import Ash.Expr

  @impl true
  def describe(_opts), do: "actor can access parent authored dashboard"

  @impl true
  def filter(%{id: actor_id, role: :system}, _authorizer, _opts) when not is_nil(actor_id) do
    expr(true)
  end

  def filter(%{id: actor_id}, _authorizer, _opts) when not is_nil(actor_id) do
    expr(
      dashboard.owner_id == ^actor_id or
        dashboard.visibility == :public or
        exists(
          dashboard.access_grants,
          access in [:view, :edit] and
            ((subject_type == :user and subject_user_id == ^actor_id) or
               (subject_type == :group and exists(subject_group.memberships, user_id == ^actor_id)))
        )
    )
  end

  def filter(_actor, _authorizer, _opts), do: expr(dashboard.visibility == :public)
end
