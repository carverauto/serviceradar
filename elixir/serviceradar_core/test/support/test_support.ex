defmodule ServiceRadar.TestSupport do
  @moduledoc false

  alias ServiceRadar.Cluster.{TenantRegistry, TenantSchemas}

  def start_core! do
    {:ok, _} = Application.ensure_all_started(:serviceradar_core)

    if Process.whereis(ServiceRadar.Repo) do
      mode =
        case System.get_env("SERVICERADAR_TEST_SANDBOX_MODE") do
          "shared" -> {:shared, self()}
          "manual" -> :manual
          _ -> :auto
        end

      Ecto.Adapters.SQL.Sandbox.mode(ServiceRadar.Repo, mode)
    end

    :ok
  end

  def create_tenant_schema!(slug_prefix) when is_binary(slug_prefix) do
    unique_id = :erlang.unique_integer([:positive])
    tenant_id = Ash.UUID.generate()
    tenant_slug = "#{slug_prefix}-#{unique_id}"

    TenantRegistry.register_slug(tenant_slug, tenant_id)
    {:ok, _schema} = TenantSchemas.create_schema(tenant_slug)

    %{tenant_id: tenant_id, tenant_slug: tenant_slug}
  end

  def drop_tenant_schema!(tenant_slug) when is_binary(tenant_slug) do
    TenantSchemas.drop_schema(tenant_slug, cascade: true)
  end
end
