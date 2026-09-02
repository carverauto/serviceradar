defmodule ServiceRadar.Dashboards.Checks.ActorCanAccessDashboardInstance do
  @moduledoc """
  Filters package dashboard instances visible to the current actor.
  """

  use Ash.Policy.FilterCheck

  import Ash.Expr

  alias ServiceRadar.Dashboards.Checks.SubjectGrant

  @impl true
  def describe(_opts), do: "actor can access package dashboard instance"

  @impl true
  def filter(%{id: actor_id, role: :system}, _authorizer, _opts) when not is_nil(actor_id) do
    expr(true)
  end

  def filter(%{id: actor_id}, _authorizer, _opts) when not is_nil(actor_id) do
    SubjectGrant.instance_access(actor_id)
  end

  def filter(_actor, _authorizer, _opts), do: expr(false)
end
