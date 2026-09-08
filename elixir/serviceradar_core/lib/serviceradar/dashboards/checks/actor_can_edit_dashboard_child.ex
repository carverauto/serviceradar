defmodule ServiceRadar.Dashboards.Checks.ActorCanEditDashboardChild do
  @moduledoc """
  Filters dashboard child resources through edit access on their parent dashboard.
  """

  use Ash.Policy.FilterCheck

  import Ash.Expr

  alias ServiceRadar.Dashboards.Checks.SubjectGrant

  @impl true
  def describe(_opts), do: "actor can edit parent authored dashboard"

  @impl true
  def filter(%{id: actor_id, role: :system}, _authorizer, _opts) when not is_nil(actor_id) do
    expr(true)
  end

  def filter(%{id: actor_id}, _authorizer, _opts) when not is_nil(actor_id) do
    SubjectGrant.parent_dashboard_edit(actor_id)
  end

  def filter(_actor, _authorizer, _opts), do: expr(false)
end
