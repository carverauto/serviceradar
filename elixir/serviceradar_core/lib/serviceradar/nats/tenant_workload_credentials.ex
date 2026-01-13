defmodule ServiceRadar.NATS.TenantWorkloadCredentials do
  @moduledoc """
  Issues NATS credentials for tenant-scoped workloads (zen consumers).
  """

  require Ash.Query
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.Tenant
  alias ServiceRadar.NATS.AccountClient

  @zen_user_prefix "zen-consumer"

  @spec issue_zen_credentials(String.t()) :: {:ok, map()} | {:error, term()}
  def issue_zen_credentials(tenant_id) when is_binary(tenant_id) do
    with {:ok, tenant} <- get_tenant(tenant_id),
         :ok <- validate_tenant_nats_ready(tenant),
         {:ok, account_seed} <- decrypt_account_seed(tenant),
         {:ok, creds} <- generate_user_credentials(tenant, account_seed) do
      {:ok,
       %{
         tenant_id: tenant.id,
         tenant_slug: to_string(tenant.slug),
         user_name: user_name(tenant.slug),
         user_public_key: creds.user_public_key,
         creds: creds.creds_file_content,
         expires_at: creds.expires_at
       }}
    end
  end

  defp get_tenant(tenant_id) do
    actor = SystemActor.platform(:tenant_workload_credentials)

    Tenant
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^tenant_id)
    |> Ash.Query.select([:id, :slug, :nats_account_status, :nats_account_seed_ciphertext])
    |> Ash.read_one(actor: actor)
    |> case do
      {:ok, nil} -> {:error, :tenant_not_found}
      {:ok, tenant} -> {:ok, tenant}
      {:error, error} -> {:error, error}
    end
  end

  defp validate_tenant_nats_ready(%{nats_account_status: :ready}), do: :ok
  defp validate_tenant_nats_ready(_), do: {:error, :tenant_nats_not_ready}

  defp decrypt_account_seed(%{nats_account_seed_ciphertext: encrypted_value}) do
    case encrypted_value do
      nil ->
        {:error, :account_seed_not_found}

      value when is_binary(value) ->
        case ServiceRadar.Vault.decrypt(value) do
          {:ok, seed} when is_binary(seed) and seed != "" ->
            {:ok, seed}

          {:ok, _} ->
            {:error, :account_seed_not_found}

          {:error, _reason} ->
            {:error, :account_seed_decrypt_failed}
        end

      _ ->
        {:error, :account_seed_not_found}
    end
  end

  defp generate_user_credentials(tenant, account_seed) do
    tenant_slug = to_string(tenant.slug)
    permissions = workload_permissions(tenant_slug)

    AccountClient.generate_user_credentials(
      tenant_slug,
      account_seed,
      user_name(tenant_slug),
      :service,
      permissions: permissions
    )
  end

  defp workload_permissions(tenant_slug) do
    %{
      publish_allow: ["$JS.API.>", "#{tenant_slug}.>"],
      subscribe_allow: ["_INBOX.>", "#{tenant_slug}.>"],
      allow_responses: true,
      max_responses: 200
    }
  end

  defp user_name(tenant_slug) do
    "#{@zen_user_prefix}-#{tenant_slug}"
  end
end
