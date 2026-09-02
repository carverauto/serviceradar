defmodule ServiceRadar.Dashboards.Checks.ActorCanEditDashboard do
  @moduledoc """
  Filters authored dashboards to records editable by the current actor.
  """

  use Ash.Policy.FilterCheck

  import Ash.Expr

  alias ServiceRadar.Dashboards.Checks.SubjectGrant

  @impl true
  def describe(_opts), do: "actor can edit authored dashboard"

  @impl true
  def filter(%{id: actor_id, role: :system}, _authorizer, _opts) when not is_nil(actor_id) do
    expr(true)
  end

  def filter(%{id: actor_id}, _authorizer, _opts) when not is_nil(actor_id) do
    SubjectGrant.authored_edit(actor_id)
  end

  def filter(_actor, _authorizer, _opts), do: expr(false)
end
