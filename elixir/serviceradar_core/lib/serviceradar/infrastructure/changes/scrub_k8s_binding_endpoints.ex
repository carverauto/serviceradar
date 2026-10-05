defmodule ServiceRadar.Infrastructure.Changes.ScrubK8sBindingEndpoints do
  @moduledoc false

  use Ash.Resource.Change

  alias ServiceRadar.Infrastructure.Changes.StampK8sBindingActor
  alias ServiceRadar.Repo

  @impl true
  def change(changeset, _opts, context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      cluster_id = Ash.Changeset.get_data(changeset, :cluster_id)
      now = DateTime.truncate(DateTime.utc_now(), :second)
      retired_by = StampK8sBindingActor.actor_name(context.actor)

      Repo.query!(
        "SELECT cluster_id FROM platform.k8s_inventory_cluster_bindings WHERE cluster_id = $1 FOR UPDATE",
        [cluster_id]
      )

      Repo.query!(
        "UPDATE platform.public_endpoints_current SET deleted_at = $1, updated_at = $1, deleted_by = $2 WHERE cluster_id = $3 AND deleted_at IS NULL",
        [now, retired_by, cluster_id]
      )

      changeset
    end)
  end
end
