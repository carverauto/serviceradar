defmodule ServiceRadar.Changes.AssignTenantId do
  @moduledoc """
  Populates tenant_id from the multitenancy context when missing.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    if changeset.action_type == :create &&
         Ash.Resource.Info.attribute(changeset.resource, :tenant_id) do
      tenant = Ash.ToTenant.to_tenant(changeset.tenant, changeset.resource)

      if tenant && is_nil(Ash.Changeset.get_attribute(changeset, :tenant_id)) do
        Ash.Changeset.force_change_attribute(changeset, :tenant_id, tenant)
      else
        changeset
      end
    else
      changeset
    end
  end
end
