defmodule ServiceRadar.Identity.Changes.AssignDefaultTenant do
  @moduledoc """
  DEPRECATED: This module is no longer needed.

  In single-tenant deployments, the DB connection's search_path determines
  the schema. Each tenant gets their own deployment instance.

  This module is kept as a no-op for backwards compatibility during migration.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    # No-op: DB connection's search_path determines the schema
    changeset
  end
end
