defmodule ServiceRadar.Dashboards.Checks.ActorCanSchedulePublicDashboard do
  @moduledoc """
  Lets an actor with report-schedule permission subscribe to a public or shared
  authored dashboard. Private dashboards still require edit access.
  """

  use Ash.Policy.SimpleCheck

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Dashboards.AuthoredDashboard

  require Ash.Query

  @impl true
  def describe(_opts), do: "actor can schedule a public or shared authored dashboard"

  @impl true
  def match?(%{id: actor_id, role: :system}, _context, _opts) when not is_nil(actor_id), do: true

  def match?(actor, %{changeset: %Ash.Changeset{} = changeset}, _opts) when not is_nil(actor) do
    with dashboard_id when not is_nil(dashboard_id) <- dashboard_id(changeset),
         {:ok, %AuthoredDashboard{} = dashboard} <- load_dashboard(dashboard_id) do
      dashboard.visibility in [:public, :shared, "public", "shared"]
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
    |> Ash.read_one(actor: SystemActor.system(:dashboard_authorization))
  end
end
