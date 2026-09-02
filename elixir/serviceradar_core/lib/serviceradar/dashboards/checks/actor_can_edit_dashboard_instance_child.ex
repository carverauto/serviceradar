defmodule ServiceRadar.Dashboards.Checks.ActorCanEditDashboardInstanceChild do
  @moduledoc """
  Filters instance grant rows through edit access on their parent instance.
  """

  use Ash.Policy.FilterCheck

  import Ash.Expr

  alias ServiceRadar.Dashboards.Checks.SubjectGrant

  @impl true
  def describe(_opts), do: "actor can edit parent package dashboard instance"

  @impl true
  def filter(%{id: actor_id, role: :system}, _authorizer, _opts) when not is_nil(actor_id) do
    expr(true)
  end

  def filter(%{id: actor_id}, _authorizer, _opts) when not is_nil(actor_id) do
    SubjectGrant.parent_instance_edit(actor_id)
  end

  def filter(_actor, _authorizer, _opts), do: expr(false)
end
