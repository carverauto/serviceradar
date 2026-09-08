defmodule ServiceRadar.Dashboards.Checks.ActorCanEditDashboardInstanceTarget do
  @moduledoc """
  Verifies that the actor can edit the target package dashboard instance.

  Filter checks cannot constrain creates because there is no child row yet, so
  this check loads the target instance id from the changeset.
  """

  use Ash.Policy.SimpleCheck

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Dashboards.Checks.SubjectGrant
  alias ServiceRadar.Dashboards.DashboardInstance

  require Ash.Query

  @impl true
  def describe(_opts), do: "actor can edit target package dashboard instance"

  @impl true
  def match?(%{id: actor_id, role: :system}, _context, _opts) when not is_nil(actor_id), do: true

  def match?(actor, %{changeset: %Ash.Changeset{} = changeset}, _opts) when not is_nil(actor) do
    with actor_id when not is_nil(actor_id) <- Map.get(actor, :id),
         instance_id when not is_nil(instance_id) <- instance_id(changeset),
         {:ok, %DashboardInstance{} = instance} <- load_instance(instance_id) do
      can_edit?(to_string(actor_id), instance)
    else
      _ -> false
    end
  end

  def match?(_actor, _context, _opts), do: false

  defp instance_id(changeset) do
    Ash.Changeset.get_attribute(changeset, :dashboard_instance_id) ||
      Map.get(changeset.data || %{}, :dashboard_instance_id)
  end

  defp load_instance(instance_id) do
    DashboardInstance
    |> Ash.Query.for_read(:by_id, %{id: instance_id})
    |> Ash.Query.load(access_grants: [subject_group: :memberships])
    |> Ash.read_one(actor: SystemActor.system(:dashboard_authorization))
  end

  defp can_edit?(actor_id, instance) do
    (instance.owner_id && to_string(instance.owner_id) == actor_id) ||
      Enum.any?(instance.access_grants || [], fn grant ->
        grant.access in [:edit, "edit"] and SubjectGrant.matches_actor?(grant, actor_id)
      end)
  end
end
