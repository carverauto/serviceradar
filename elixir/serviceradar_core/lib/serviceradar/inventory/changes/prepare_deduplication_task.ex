defmodule ServiceRadar.Inventory.Changes.PrepareDeduplicationTask do
  @moduledoc false
  # Normalizes the device set, derives the candidate key from it, and stamps the decision time.
  # On a repeat the upsert keeps the task's identity, status, category and opened_at, and takes
  # the new last decision, evidence and time.
  use Ash.Resource.Change

  alias ServiceRadar.Inventory.DeduplicationTask

  @impl true
  def change(changeset, _opts, _context) do
    now = DateTime.utc_now()

    uids =
      DeduplicationTask.normalize_uids(Ash.Changeset.get_attribute(changeset, :device_uids) || [])

    changeset
    |> Ash.Changeset.force_change_attribute(:device_uids, uids)
    |> Ash.Changeset.force_change_attribute(:candidate_key, DeduplicationTask.candidate_key(uids))
    |> Ash.Changeset.force_change_attribute(:opened_at, now)
    |> Ash.Changeset.force_change_attribute(:last_decided_at, now)
  end
end
