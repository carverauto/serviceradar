defmodule ServiceRadar.Identity.Changes.InvalidateUserRbacCache do
  @moduledoc """
  Ash change that invalidates a specific user's RBAC permission cache after action.

  Used on User update_role and update_role_profile since these only affect
  the single user being modified.
  """
  use Ash.Resource.Change

  alias ServiceRadar.Changes.AfterAction

  @impl true
  def change(changeset, _opts, _context) do
    AfterAction.after_action(changeset, &ServiceRadar.Identity.RBAC.invalidate_user_cache(&1.id))
  end

  @impl true
  def atomic(_changeset, _opts, _context), do: :ok
end
