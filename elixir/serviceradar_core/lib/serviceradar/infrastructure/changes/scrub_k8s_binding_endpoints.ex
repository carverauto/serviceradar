defmodule ServiceRadar.Infrastructure.Changes.ScrubK8sBindingEndpoints do
  @moduledoc false

  use Ash.Resource.Change

  alias ServiceRadar.Repo

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      cluster_id = Ash.Changeset.get_data(changeset, :cluster_id)
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      Repo.query!(
        "UPDATE platform.public_endpoints_current SET deleted_at = $1, updated_at = $1 WHERE cluster_id = $2 AND deleted_at IS NULL",
        [now, cluster_id]
      )

      changeset
    end)
  end
end
