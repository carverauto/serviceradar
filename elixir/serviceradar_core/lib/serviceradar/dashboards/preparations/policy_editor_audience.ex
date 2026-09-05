defmodule ServiceRadar.Dashboards.Preparations.PolicyEditorAudience do
  @moduledoc false

  use Ash.Resource.Preparation

  alias ServiceRadar.Dashboards.DashboardAccessGrant
  alias ServiceRadar.Dashboards.DashboardInstanceAccessGrant

  require Ash.Query

  @impl true
  def prepare(query, opts, context) do
    group_id = Ash.Query.get_argument(query, :group_id)

    grant_query =
      opts
      |> Keyword.fetch!(:source)
      |> grant_resource()
      |> Ash.Query.for_read(:read, %{}, actor: context.actor, authorize?: context.authorize?)
      |> Ash.Query.filter(subject_type == :group and subject_group_id == ^group_id)
      |> Ash.Query.limit(1)

    query
    |> Ash.Query.unset(:sort)
    |> Ash.Query.sort(policy_editor_sort_key: :asc, id: :asc)
    |> Ash.Query.load(access_grants: grant_query)
  end

  defp grant_resource(:authored), do: DashboardAccessGrant
  defp grant_resource(:package), do: DashboardInstanceAccessGrant
end
