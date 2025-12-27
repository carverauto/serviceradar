defmodule ServiceRadar.Identity.Changes.AssignDefaultTenant do
  @moduledoc """
  Ensures user registration actions have a tenant_id assigned.

  Defaults to the configured tenant when none is provided.
  """

  use Ash.Resource.Change

  @default_tenant_id "00000000-0000-0000-0000-000000000000"

  @impl true
  def change(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :tenant_id) do
      nil ->
        Ash.Changeset.change_attribute(changeset, :tenant_id, default_tenant_id())

      _ ->
        changeset
    end
  end

  defp default_tenant_id do
    Application.get_env(:serviceradar_core, :default_tenant_id, @default_tenant_id)
  end
end
