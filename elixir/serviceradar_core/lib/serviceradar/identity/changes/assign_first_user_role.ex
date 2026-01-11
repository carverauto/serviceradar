defmodule ServiceRadar.Identity.Changes.AssignFirstUserRole do
  @moduledoc """
  Assigns super_admin role to the first user registered for a tenant.

  When a user registers and is the first user for their tenant, they are
  automatically granted super_admin role. Subsequent users get the default
  viewer role.

  This ensures every tenant has at least one super_admin who can manage
  the tenant's users and settings.
  """

  use Ash.Resource.Change

  alias ServiceRadar.Cluster.TenantSchemas

  require Logger

  @impl true
  def change(changeset, _opts, _context) do
    # Only apply during create actions
    if changeset.action_type != :create do
      changeset
    else
      # Check if role is already explicitly set
      case Ash.Changeset.get_attribute(changeset, :role) do
        nil ->
          maybe_assign_super_admin(changeset)

        :viewer ->
          # Default was applied, check if we should override
          maybe_assign_super_admin(changeset)

        _other_role ->
          # Role was explicitly set, don't override
          changeset
      end
    end
  end

  defp maybe_assign_super_admin(changeset) do
    tenant_id = Ash.Changeset.get_attribute(changeset, :tenant_id)

    if is_nil(tenant_id) do
      # No tenant yet, can't check - leave default
      changeset
    else
      if first_user_for_tenant?(tenant_id) do
        Logger.info("Assigning super_admin role to first user for tenant #{tenant_id}")
        Ash.Changeset.force_change_attribute(changeset, :role, :super_admin)
      else
        changeset
      end
    end
  end

  defp first_user_for_tenant?(tenant_id) do
    schema = TenantSchemas.schema_for_id(tenant_id)

    if is_nil(schema) do
      # Can't determine schema, assume not first user for safety
      false
    else
      count = count_users_in_tenant(schema)
      count == 0
    end
  end

  defp count_users_in_tenant(schema) do
    import Ecto.Query

    query =
      from(u in {"ng_users", ServiceRadar.Identity.User},
        select: count(u.id)
      )

    case ServiceRadar.Repo.one(query, prefix: schema) do
      nil -> 0
      count -> count
    end
  rescue
    _ -> 0
  end
end
