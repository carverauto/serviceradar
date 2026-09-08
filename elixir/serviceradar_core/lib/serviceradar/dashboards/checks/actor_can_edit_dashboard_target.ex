defmodule ServiceRadar.Dashboards.Checks.ActorCanEditDashboardTarget do
  @moduledoc """
  Verifies that the actor can edit the target authored dashboard on create/update actions.

  Filter checks cannot constrain creates because there is no child row yet, so
  this check loads the target dashboard id from the changeset.
  """

  use Ash.Policy.SimpleCheck

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Dashboards.AuthoredDashboard
  alias ServiceRadar.Dashboards.Checks.SubjectGrant

  require Ash.Query

  @impl true
  def describe(_opts), do: "actor can edit target authored dashboard"

  @impl true
  def match?(%{id: actor_id, role: :system}, _context, _opts) when not is_nil(actor_id), do: true

  def match?(actor, %{changeset: %Ash.Changeset{} = changeset}, _opts) when not is_nil(actor) do
    with actor_id when not is_nil(actor_id) <- Map.get(actor, :id),
         dashboard_id when not is_nil(dashboard_id) <- dashboard_id(changeset),
         {:ok, %AuthoredDashboard{} = dashboard} <- load_dashboard(dashboard_id) do
      can_edit?(to_string(actor_id), dashboard)
    else
      _ -> false
    end
  end

  def match?(_actor, _context, _opts), do: false

  defp dashboard_id(changeset) do
    Ash.Changeset.get_attribute(changeset, :dashboard_id) ||
      Map.get(changeset.data || %{}, :dashboard_id)
  end

  defp load_dashboard(dashboard_id) do
    AuthoredDashboard
    |> Ash.Query.for_read(:by_id, %{id: dashboard_id})
    |> Ash.Query.load(access_grants: [subject_group: :memberships])
    |> Ash.read_one(actor: SystemActor.system(:dashboard_authorization))
  end

  defp can_edit?(actor_id, dashboard) do
    (dashboard.owner_id && to_string(dashboard.owner_id) == actor_id) ||
      Enum.any?(dashboard.access_grants || [], fn grant ->
        grant.access in [:edit, "edit"] and SubjectGrant.matches_actor?(grant, actor_id)
      end)
  end
end
