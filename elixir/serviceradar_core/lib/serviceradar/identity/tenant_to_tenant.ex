defimpl Ash.ToTenant, for: ServiceRadar.Identity.Tenant do
  alias ServiceRadar.Cluster.TenantSchemas

  def to_tenant(%{id: id} = tenant, resource) do
    case Ash.Resource.Info.multitenancy_strategy(resource) do
      :context -> TenantSchemas.schema_for_tenant(tenant)
      :attribute -> id
      _ -> id
    end
  end
end
