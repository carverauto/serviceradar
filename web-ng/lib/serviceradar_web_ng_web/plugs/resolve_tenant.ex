defmodule ServiceRadarWebNGWeb.Plugs.ResolveTenant do
  @moduledoc false

  import Plug.Conn

  alias ServiceRadar.Cluster.TenantSchemas
  alias ServiceRadarWebNGWeb.TenantResolver

  def init(opts), do: opts

  def call(conn, _opts) do
    conn
    |> maybe_set_from_host()
    |> maybe_set_from_session()
    |> maybe_set_from_default()
  end

  defp maybe_set_from_host(conn) do
    case TenantResolver.resolve_host_tenant(conn.host) do
      {:ok, tenant} ->
        schema = TenantSchemas.schema_for_tenant(tenant)

        conn
        |> put_session("tenant", schema)
        |> put_session("active_tenant_id", tenant.id)
        |> Ash.PlugHelpers.set_tenant(schema)

      :error ->
        conn
    end
  end

  defp maybe_set_from_session(conn) do
    if Ash.PlugHelpers.get_tenant(conn) do
      conn
    else
      resolve_tenant_from_session(conn)
    end
  end

  defp resolve_tenant_from_session(conn) do
    with nil <- get_session(conn, "tenant"),
         tenant_id when is_binary(tenant_id) <- get_session(conn, "active_tenant_id"),
         schema when is_binary(schema) <- TenantResolver.schema_for_tenant_id(tenant_id) do
      conn
      |> put_session("tenant", schema)
      |> Ash.PlugHelpers.set_tenant(schema)
    else
      tenant_schema when is_binary(tenant_schema) ->
        Ash.PlugHelpers.set_tenant(conn, tenant_schema)

      _ ->
        conn
    end
  end

  defp maybe_set_from_default(conn) do
    case Ash.PlugHelpers.get_tenant(conn) do
      nil ->
        default_schema = TenantResolver.default_tenant_schema()
        default_tenant_id = TenantResolver.default_tenant_id()

        if default_schema do
          conn
          |> put_session("tenant", default_schema)
          |> put_session("active_tenant_id", default_tenant_id)
          |> Ash.PlugHelpers.set_tenant(default_schema)
        else
          conn
        end

      _ ->
        conn
    end
  end
end
