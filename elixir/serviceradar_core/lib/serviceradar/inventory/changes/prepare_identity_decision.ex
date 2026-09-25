defmodule ServiceRadar.Inventory.Changes.PrepareIdentityDecision do
  @moduledoc false
  # Normalizes the device set, derives the decision key from the identifying columns, and
  # stamps the decision time. On a repeat the upsert keeps the first row's identity and
  # first_decided_at and takes the new last_decided_at and evidence.
  use Ash.Resource.Change

  alias ServiceRadar.Inventory.IdentityDecision

  @impl true
  def change(changeset, _opts, _context) do
    now = DateTime.utc_now()

    uids =
      IdentityDecision.normalize_uids(Ash.Changeset.get_attribute(changeset, :device_uids) || [])

    key =
      IdentityDecision.decision_key(
        Ash.Changeset.get_attribute(changeset, :decision_kind),
        Ash.Changeset.get_attribute(changeset, :reason) || "",
        uids,
        Ash.Changeset.get_attribute(changeset, :subject)
      )

    changeset
    |> Ash.Changeset.force_change_attribute(:device_uids, uids)
    |> Ash.Changeset.force_change_attribute(:decision_key, key)
    |> Ash.Changeset.force_change_attribute(:first_decided_at, now)
    |> Ash.Changeset.force_change_attribute(:last_decided_at, now)
  end
end
