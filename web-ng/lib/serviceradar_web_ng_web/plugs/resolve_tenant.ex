defmodule ServiceRadarWebNGWeb.Plugs.ResolveTenant do
  @moduledoc """
  Optional plug for setting Ash tenant context in single-tenant instance deployments.

  This is a tenant instance UI - each instance serves ONE tenant. The tenant
  is typically implicit from the PostgreSQL search_path set by infrastructure.

  This plug only sets Ash tenant context if :default_tenant_schema is explicitly
  configured. In most deployments, this configuration is not needed since the
  database connection already has the correct search_path.

  ## Configuration

  If you need to explicitly set the Ash tenant schema:

      config :serviceradar_web_ng, :default_tenant_schema, "tenant_abc123"

  Otherwise, leave unconfigured and the database search_path will be used.
  """

  alias ServiceRadarWebNGWeb.TenantResolver

  def init(opts), do: opts

  def call(conn, _opts) do
    case TenantResolver.default_tenant_schema() do
      nil ->
        # No explicit tenant schema configured - rely on database search_path
        conn

      tenant_schema ->
        # Explicitly set Ash tenant context
        Ash.PlugHelpers.set_tenant(conn, tenant_schema)
    end
  end
end
