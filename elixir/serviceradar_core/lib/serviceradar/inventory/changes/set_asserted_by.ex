defmodule ServiceRadar.Inventory.Changes.SetAssertedBy do
  @moduledoc false
  # Stamps who asserted a distinct-device pair.
  use Ash.Resource.Change

  alias ServiceRadar.Inventory.Changes.SetResolvedBy

  @impl true
  def change(changeset, _opts, context) do
    Ash.Changeset.force_change_attribute(
      changeset,
      :asserted_by,
      SetResolvedBy.actor_name(context.actor)
    )
  end
end
