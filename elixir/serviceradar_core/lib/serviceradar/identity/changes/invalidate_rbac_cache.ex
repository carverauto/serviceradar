defmodule ServiceRadar.Identity.Changes.InvalidateRbacCache do
  @moduledoc """
  Ash change that invalidates the entire RBAC permission cache after action.

  Used on RoleProfile create/update/destroy since profile changes can
  affect any user assigned to that profile.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, record ->
      ServiceRadar.Identity.RBAC.invalidate_all_caches()
      {:ok, record}
    end)
  end

  @impl true
  def atomic(_changeset, _opts, _context), do: :ok
end
