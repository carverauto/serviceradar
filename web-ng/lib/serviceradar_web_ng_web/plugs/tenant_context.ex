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
        partition_id = get_partition_id(conn)

        conn
        |> assign(:current_tenant_id, user.tenant_id)
        |> assign(:current_partition_id, partition_id)
        |> assign(:ash_actor, build_actor(user, partition_id))
    end
  end

  # Extract partition ID from header or session
  defp get_partition_id(conn) do
    case get_req_header(conn, "x-partition-id") do
      [partition_id | _] when byte_size(partition_id) > 0 ->
        validate_uuid(partition_id)

      _ ->
        conn.assigns[:current_partition_id] || get_session(conn, :current_partition_id)
    end
  end

  defp validate_uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> uuid
      :error -> nil
    end
  end

  defp validate_uuid(_), do: nil

  @doc """
  Build an Ash-compatible actor map from a user.

  This actor is used for Ash policy evaluation and includes:
  - User ID
  - Tenant ID for multi-tenant isolation
  - Role for RBAC policies
  - Partition ID for partition-scoped access (optional)
  """
  def build_actor(user, partition_id \\ nil)
  def build_actor(nil, _partition_id), do: nil

  def build_actor(user, partition_id) do
    actor = %{
      id: user.id,
      tenant_id: user.tenant_id,
      role: user.role,
      email: user.email
    }

    if partition_id do
      Map.put(actor, :partition_id, partition_id)
    else
      actor
    end
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
