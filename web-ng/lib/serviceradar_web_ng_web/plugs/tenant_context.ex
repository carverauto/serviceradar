defmodule ServiceRadarWebNGWeb.Plugs.TenantContext do
  @moduledoc """
  Plug for setting tenant context in connections.

  This plug extracts tenant information from the authenticated user
  and stores it in the connection assigns for use in controllers and LiveViews.

  ## Usage

  In your router pipeline:

      pipeline :browser do
        plug :fetch_current_user
        plug ServiceRadarWebNGWeb.Plugs.TenantContext
      end

  ## Assigns

  - `:current_tenant_id` - UUID of the current tenant
  - `:current_tenant` - Full tenant struct (lazy-loaded on demand)

  ## Ash Integration

  The tenant context is also used to create the Ash actor for policy enforcement:

      actor = %{
        id: user.id,
        tenant_id: user.tenant_id,
        role: user.role
      }
  """

  import Plug.Conn

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case conn.assigns[:current_user] do
      nil ->
        conn

      user ->
        conn
        |> assign(:current_tenant_id, user.tenant_id)
        |> assign(:ash_actor, build_actor(user))
    end
  end

  @doc """
  Build an Ash-compatible actor map from a user.

  This actor is used for Ash policy evaluation and includes:
  - User ID
  - Tenant ID for multi-tenant isolation
  - Role for RBAC policies
  """
  def build_actor(nil), do: nil

  def build_actor(user) do
    %{
      id: user.id,
      tenant_id: user.tenant_id,
      role: user.role,
      email: user.email
    }
  end

  @doc """
  Get the current tenant from the connection.

  Lazy-loads the tenant on first access and caches it.
  """
  def get_tenant(conn) do
    case conn.assigns[:current_tenant] do
      nil ->
        tenant_id = conn.assigns[:current_tenant_id]

        if tenant_id do
          case load_tenant(tenant_id) do
            {:ok, tenant} ->
              {assign(conn, :current_tenant, tenant), tenant}

            {:error, _} ->
              {conn, nil}
          end
        else
          {conn, nil}
        end

      tenant ->
        {conn, tenant}
    end
  end

  defp load_tenant(tenant_id) do
    # Use Ash to load the tenant
    require Ash.Query

    ServiceRadar.Identity.Tenant
    |> Ash.Query.filter(id == ^tenant_id)
    |> Ash.read_one(authorize?: false)
  end
end
