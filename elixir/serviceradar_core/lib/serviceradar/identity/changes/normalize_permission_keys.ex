defmodule ServiceRadar.Identity.Changes.NormalizePermissionKeys do
  @moduledoc """
  Canonicalizes permission keys before validation/persistence.

  This primarily exists to expand deprecated keys (aliases) so older role
  profiles can still be edited and saved after RBAC catalog refinements.
  """

  use Ash.Resource.Change

  alias ServiceRadar.Identity.RBAC.Catalog

  @impl Ash.Resource.Change
  def change(changeset, _opts, _context) do
    perms = Ash.Changeset.get_attribute(changeset, :permissions)

    if is_list(perms) do
      Ash.Changeset.force_change_attribute(changeset, :permissions, Catalog.normalize_permission_keys(perms))
    else
      changeset
    end
  end

  @impl true
  def atomic(_changeset, _opts, _context), do: :ok
end

