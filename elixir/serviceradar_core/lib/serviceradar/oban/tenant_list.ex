defmodule ServiceRadar.Oban.TenantList do
  @moduledoc """
  Provides tenant schema list for AshOban schedulers.
  """

  @behaviour AshOban.ListTenants

  @impl true
  def list_tenants(_opts) do
    ServiceRadar.Cluster.TenantSchemas.list_schemas()
  end
end
