defmodule ServiceRadar.Inventory.Changes.RotateRumSiteKey do
  @moduledoc """
  Atomically generates a fresh `sr_rum_...` site key for `WebProperty.:rotate_rum_site_key`.
  """

  use Ash.Resource.Change

  alias ServiceRadar.Inventory.Changes.NormalizeWebProperty

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.force_change_attribute(
      changeset,
      :rum_site_key,
      NormalizeWebProperty.generate_rum_site_key()
    )
  end

  @impl true
  def atomic(_changeset, _opts, _context) do
    {:atomic, %{rum_site_key: NormalizeWebProperty.generate_rum_site_key()}}
  end
end
