defmodule ServiceRadarWebNG.Api.TenantWorkloadController do
  @moduledoc """
  JSON API controller for workload credential requests.

  In a tenant instance UI, the tenant is implicit from the deployment.
  The configured default tenant record is used to load the tenant context.
  """

  use ServiceRadarWebNGWeb, :controller

  alias ServiceRadarWebNG.Accounts.Scope

  action_fallback ServiceRadarWebNG.Api.FallbackController

  @doc """
  POST /api/admin/workloads/credentials

  Issues workload-specific credentials (currently zen-consumer).
  The tenant is determined from the instance configuration.
  """
  def credentials(conn, params) do
    workload = Map.get(params, "workload", "zen-consumer")

    with {:ok, tenant} <- require_tenant(conn) do
      case workload do
        "zen-consumer" ->
          issue_zen_credentials(conn, tenant)

        _ ->
          return_error(conn, :bad_request, "Unsupported workload: #{workload}")
      end
    end
  end

  defp issue_zen_credentials(conn, _tenant) do
    # Workload credentials are now provisioned by the control plane
    # in the single-tenant-per-deployment architecture
    return_error(
      conn,
      :not_implemented,
      "Workload credentials are provisioned by the control plane"
    )
  end

  # In a tenant instance UI, the tenant is implicit from the deployment.
  # DB connection's search_path determines the schema.
  defp require_tenant(conn) do
    case conn.assigns[:current_scope] do
      %Scope{} ->
        # In single-tenant-per-deployment architecture, tenant context is implicit
        {:ok, %{slug: "default"}}

      _ ->
        {:error, :unauthorized}
    end
  end

  defp return_error(conn, status, message) do
    conn
    |> put_status(status)
    |> json(%{error: message})
  end
end
