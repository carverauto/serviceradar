defmodule ServiceRadar.Identity.Changes.InvalidateUserRbacCache do
  @moduledoc """
  Ash change that invalidates a specific user's RBAC permission cache after transaction.

  Used on User update_role and update_role_profile since these only affect
  the single user being modified.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    if Map.get(changeset.context, :privilege_boundary_owned) == true do
      changeset
    else
      Ash.Changeset.after_transaction(changeset, fn _changeset, result ->
        case result do
          {:ok, record} ->
            ServiceRadar.Identity.RBAC.invalidate_user_cache(record.id)
            {:ok, record}

          other ->
            other
        end
      end)
    end
  end

  @impl true
  def atomic(changeset, opts, context), do: {:ok, change(changeset, opts, context)}
end
