defmodule ServiceRadarWebNG.Api.TenantWorkloadController do
  @moduledoc """
  JSON API controller for workload credential requests.

  In a tenant instance UI, the tenant is implicit from the deployment.
  The configured default tenant record is used to load the tenant context.
  """

  use ServiceRadarWebNGWeb, :controller

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.Tenant
  alias ServiceRadar.NATS.TenantWorkloadCredentials
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
    # Tenant is implicit from DB search_path in a tenant instance
    case TenantWorkloadCredentials.issue_zen_credentials() do
      {:ok, result} ->
        json(conn, %{
          tenant_slug: result.tenant_slug,
          user_name: result.user_name,
          user_public_key: result.user_public_key,
          creds: result.creds,
          expires_at: format_datetime(result.expires_at)
        })

      {:error, :tenant_not_found} ->
        {:error, :not_found}

      {:error, :tenant_nats_not_ready} ->
        return_error(conn, :conflict, "NATS account not ready")

      {:error, :account_seed_not_found} ->
        return_error(conn, :not_found, "NATS seed not available")

      {:error, :account_seed_decrypt_failed} ->
        return_error(conn, :internal_server_error, "Failed to decrypt NATS seed")

      {:error, reason} ->
        return_error(
          conn,
          :internal_server_error,
          "Failed to issue credentials: #{inspect(reason)}"
        )
    end
  end

  # In a tenant instance UI, the tenant is implicit from the deployment.
  # We use the configured default tenant to load the tenant context.
  defp require_tenant(conn) do
    case conn.assigns[:current_scope] do
      %Scope{} ->
        load_default_tenant()

      _ ->
        {:error, :unauthorized}
    end
  end

  defp load_default_tenant do
    default_id = Application.get_env(:serviceradar_core, :default_tenant_id)

    if default_id do
      actor = SystemActor.platform(:tenant_workload_controller)

      case Ash.get(Tenant, default_id, actor: actor) do
        {:ok, %Tenant{} = tenant} -> {:ok, tenant}
        _ -> {:error, :tenant_not_configured}
      end
    else
      {:error, :tenant_not_configured}
    end
  end

  defp return_error(conn, status, message) do
    conn
    |> put_status(status)
    |> json(%{error: message})
  end

  defp format_datetime(nil), do: nil
  defp format_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
end
