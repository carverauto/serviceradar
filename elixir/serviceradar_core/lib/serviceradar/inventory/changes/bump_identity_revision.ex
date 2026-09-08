defmodule ServiceRadar.Inventory.Changes.BumpIdentityRevision do
  @moduledoc """
  Increments a device's `identity_revision`.

  The increment is expressed as a database expression rather than read-modify-write
  in Elixir, so two identity transitions committing concurrently against the same
  device cannot lose a bump. That is the whole point of the column: a fence that can
  miss an increment is not a fence.

  `identity_revision` is NOT NULL with a default, so no nil-safe branch is needed.
  If the column is ever made nullable, add one -- `NULL + 1` is `NULL`, and a NULL
  revision silently matches nothing, which fails open.

  Deliberately a dedicated change rather than Ash `optimistic_lock/1`: that bumps on
  every update, and `Device` takes high-frequency non-identity writes through
  `:touch`, `:gateway_sync` and `:set_availability`. This must move only when the
  device's identity actually changes.
  """

  use Ash.Resource.Change

  import Ash.Expr

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.change_attribute(
      changeset,
      :identity_revision,
      changeset.data.identity_revision + 1
    )
  end

  @impl true
  def atomic(_changeset, _opts, _context) do
    {:atomic, %{identity_revision: expr(^atomic_ref(:identity_revision) + 1)}}
  end
end
