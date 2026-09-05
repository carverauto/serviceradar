defmodule ServiceRadar.Identity.Changes.InvalidateRbacCache do
  @moduledoc """
  Ash change that invalidates the entire RBAC permission cache after transaction.

  Used on RoleProfile create/update/destroy since profile changes can
  affect any user assigned to that profile.
  """
  use Ash.Resource.Change

  alias ServiceRadar.Identity.RBAC

  @impl true
  def change(changeset, _opts, _context) do
    if Map.get(changeset.context, :privilege_boundary_owned) == true do
      changeset
    else
      Ash.Changeset.after_transaction(changeset, fn _changeset, result ->
        case result do
          {:ok, record} ->
            RBAC.invalidate_all_caches()
            {:ok, record}

          :ok ->
            RBAC.invalidate_all_caches()
            :ok

          other ->
            other
        end
      end)
    end
  end

  @impl true
  def atomic(changeset, opts, context), do: {:ok, change(changeset, opts, context)}
end
