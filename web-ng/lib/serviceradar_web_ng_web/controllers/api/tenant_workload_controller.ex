defmodule ServiceRadarWebNG.Api.TenantWorkloadController do
  @moduledoc """
  JSON API controller for tenant workload credential requests.
  """

  use ServiceRadarWebNGWeb, :controller

  alias ServiceRadar.NATS.TenantWorkloadCredentials

  action_fallback ServiceRadarWebNG.Api.FallbackController

  @doc """
  POST /api/admin/tenant-workloads/:id/credentials

  Issues workload-specific credentials (currently zen-consumer).
  """
  def credentials(conn, %{"id" => tenant_id} = params) do
    workload = Map.get(params, "workload", "zen-consumer")

    case workload do
      "zen-consumer" ->
        issue_zen_credentials(conn, tenant_id)

      _ ->
        return_error(conn, :bad_request, "Unsupported workload: #{workload}")
    end
  end

  defp issue_zen_credentials(conn, tenant_id) do
    case TenantWorkloadCredentials.issue_zen_credentials(tenant_id) do
      {:ok, result} ->
        json(conn, %{
          tenant_id: result.tenant_id,
          tenant_slug: result.tenant_slug,
          user_name: result.user_name,
          user_public_key: result.user_public_key,
          creds: result.creds,
          expires_at: format_datetime(result.expires_at)
        })

      {:error, :tenant_not_found} ->
        {:error, :not_found}

      {:error, :tenant_nats_not_ready} ->
        return_error(conn, :conflict, "Tenant NATS account not ready")

      {:error, :account_seed_not_found} ->
        return_error(conn, :not_found, "Tenant NATS seed not available")

      {:error, :account_seed_decrypt_failed} ->
        return_error(conn, :internal_server_error, "Failed to decrypt tenant NATS seed")

      {:error, reason} ->
        return_error(
          conn,
          :internal_server_error,
          "Failed to issue credentials: #{inspect(reason)}"
        )
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
