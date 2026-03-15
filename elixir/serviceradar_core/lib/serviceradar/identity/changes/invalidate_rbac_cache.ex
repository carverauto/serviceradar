defmodule ServiceRadar.Identity.Changes.InvalidateRbacCache do
  @moduledoc """
  Ash change that invalidates the entire RBAC permission cache after action.

  Used on RoleProfile create/update/destroy since profile changes can
  affect any user assigned to that profile.
  """
  use Ash.Resource.Change

  alias ServiceRadar.Changes.AfterAction

  @impl true
  def change(changeset, _opts, _context) do
    AfterAction.after_action(changeset, fn _record ->
      ServiceRadar.Identity.RBAC.invalidate_all_caches()
    end)
  end

  @impl true
  def atomic(_changeset, _opts, _context), do: :ok
end
