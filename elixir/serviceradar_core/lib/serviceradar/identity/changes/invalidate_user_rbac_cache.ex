defmodule ServiceRadar.Identity.Changes.InvalidateUserRbacCache do
  @moduledoc """
  Ash change that invalidates a specific user's RBAC permission cache after action.

  Used on User update_role and update_role_profile since these only affect
  the single user being modified.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, user ->
      ServiceRadar.Identity.RBAC.invalidate_user_cache(user.id)
      {:ok, user}
    end)
  end

  @impl true
  def atomic(_changeset, _opts, _context), do: :ok
end
