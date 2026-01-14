defmodule ServiceRadar.NATS.ServiceAccountBootstrap do
  @moduledoc """
  Provisions the tenant workload operator NATS account and credentials.
  """

  require Logger
  require Ash.Query

  alias Ash.Resource.Info, as: AshResourceInfo
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.Tenant
  alias ServiceRadar.Identity.TenantLifecyclePublisher
  alias ServiceRadar.Infrastructure.NatsServiceAccount
  alias ServiceRadar.NATS.AccountClient

  @operator_account_name "tenant-workload-operator"
  @operator_account_slug "serviceradar-operator"
  @operator_user_name "tenant-workload-operator"

  @spec ensure_operator_account() :: {:ok, NatsServiceAccount.t()} | {:error, term()}
  def ensure_operator_account do
    case get_service_account() do
      {:ok, %NatsServiceAccount{status: :ready} = account} ->
        {:ok, account}

      _ ->
        provision_operator_account()
    end
  end

  defp get_service_account do
    actor = SystemActor.platform(:nats_service_account)

    NatsServiceAccount
    |> Ash.Query.for_read(:by_name, %{name: @operator_account_name})
    |> Ash.read_one(actor: actor)
  end

  defp provision_operator_account do
    actor = SystemActor.platform(:nats_service_account)

    with {:ok, platform_tenant} <- get_platform_tenant(),
         :ok <- ensure_platform_account_ready(platform_tenant),
         {:ok, platform_seed} <- decrypt_account_seed(platform_tenant),
         :ok <- ensure_platform_exports(platform_tenant, platform_seed),
         {:ok, account} <- AccountClient.create_tenant_account(@operator_account_slug),
         {:ok, signed} <- sign_operator_account(account.account_seed, platform_tenant),
         :ok <- push_account_jwt(signed),
         {:ok, creds} <- generate_operator_creds(account.account_seed),
         {:ok, service_account} <-
           upsert_service_account(actor, signed, account.account_seed, creds) do
      {:ok, service_account}
    else
      {:error, reason} ->
        Logger.warning("Failed to provision operator NATS account", reason: inspect(reason))
        record_error(reason)
    end
  end

  defp ensure_platform_exports(platform_tenant, platform_seed) do
    with {:ok, import_tenants} <- load_import_tenants(),
         imports <- build_stream_imports(import_tenants),
         exports <- build_platform_exports(),
         {:ok, result} <-
           AccountClient.sign_account_jwt(
             to_string(platform_tenant.slug),
             platform_seed,
             imports: imports,
             exports: exports
           ),
         {:ok, _tenant} <- update_platform_jwt(platform_tenant, result.account_jwt),
         :ok <- push_platform_jwt(platform_tenant, result.account_jwt) do
      :ok
    else
      {:error, reason} ->
        Logger.warning("[NATS] Failed to update platform exports", reason: inspect(reason))
        {:error, reason}
    end
  end

  defp build_platform_exports do
    [
      %{
        subject: TenantLifecyclePublisher.subject_pattern(),
        name: "tenant-provisioning"
      }
    ]
  end

  defp sign_operator_account(account_seed, platform_tenant) do
    imports = [
      %{
        subject: TenantLifecyclePublisher.subject_pattern(),
        account_public_key: platform_tenant.nats_account_public_key
      }
    ]

    AccountClient.sign_account_jwt(@operator_account_slug, account_seed, imports: imports)
  end

  defp generate_operator_creds(account_seed) do
    permissions = %{
      publish_allow: ["$JS.API.>"],
      subscribe_allow: [TenantLifecyclePublisher.subject_pattern(), "_INBOX.>"],
      allow_responses: true,
      max_responses: 100
    }

    AccountClient.generate_user_credentials(
      @operator_account_slug,
      account_seed,
      @operator_user_name,
      :service,
      permissions: permissions
    )
  end

  defp upsert_service_account(actor, signed, account_seed, creds) do
    case get_service_account() do
      {:ok, %NatsServiceAccount{} = account} ->
        account
        |> Ash.Changeset.for_update(
          :set_ready,
          %{
            account_public_key: signed.account_public_key,
            account_seed: account_seed,
            account_jwt: signed.account_jwt,
            user_public_key: creds.user_public_key,
            user_creds: creds.creds_file_content
          },
          actor: actor
        )
        |> Ash.update()

      _ ->
        NatsServiceAccount
        |> Ash.Changeset.for_create(
          :provision,
          %{
            name: @operator_account_name,
            account_public_key: signed.account_public_key,
            account_seed: account_seed,
            account_jwt: signed.account_jwt,
            user_public_key: creds.user_public_key,
            user_creds: creds.creds_file_content
          },
          actor: actor
        )
        |> Ash.create()
    end
  end

  defp record_error(reason) do
    actor = SystemActor.platform(:nats_service_account)

    case get_service_account() do
      {:ok, %NatsServiceAccount{} = account} ->
        account
        |> Ash.Changeset.for_update(:set_error, %{error_message: inspect(reason)}, actor: actor)
        |> Ash.update()

      _ ->
        {:error, reason}
    end
  end

  defp get_platform_tenant do
    actor = SystemActor.platform(:nats_service_account)
    seed_attr = seed_attribute()
    select_fields =
      case seed_attr do
        nil ->
          [
            :id,
            :slug,
            :nats_account_public_key,
            :nats_account_status,
            :nats_account_jwt
          ]

        attr ->
          [
            :id,
            :slug,
            :nats_account_public_key,
            :nats_account_status,
            :nats_account_jwt,
            attr
          ]
      end

    Tenant
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(is_platform_tenant == true)
    |> Ash.Query.select(select_fields)
    |> Ash.read_one(actor: actor)
    |> case do
      {:ok, nil} -> {:error, :platform_missing}
      {:ok, tenant} -> {:ok, tenant}
      {:error, error} -> {:error, error}
    end
  end

  defp ensure_platform_account_ready(platform_tenant) do
    if platform_tenant.nats_account_status == :ready and platform_tenant.nats_account_jwt != nil and
         platform_tenant.nats_account_public_key != nil do
      :ok
    else
      {:error, :platform_not_ready}
    end
  end

  defp decrypt_account_seed(tenant) do
    encrypted_value = account_seed_ciphertext(tenant)

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

  defp account_seed_ciphertext(tenant) do
    Map.get(tenant, :nats_account_seed_ciphertext) ||
      Map.get(tenant, :encrypted_nats_account_seed_ciphertext)
  end

  defp seed_attribute do
    cond do
      AshResourceInfo.attribute(Tenant, :nats_account_seed_ciphertext) ->
        :nats_account_seed_ciphertext

      AshResourceInfo.attribute(Tenant, :encrypted_nats_account_seed_ciphertext) ->
        :encrypted_nats_account_seed_ciphertext

      true ->
        nil
    end
  end

  defp load_import_tenants do
    actor = SystemActor.platform(:nats_service_account)

    Tenant
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(
      status == :active and is_platform_tenant == false and nats_account_status == :ready and
        not is_nil(nats_account_public_key)
    )
    |> Ash.Query.select([:slug, :nats_account_public_key])
    |> Ash.read(actor: actor)
  end

  defp build_stream_imports(tenants) when is_list(tenants) do
    Enum.flat_map(tenants, fn tenant ->
      slug = to_string(tenant.slug)
      account_key = tenant.nats_account_public_key

      [
        %{subject: "#{slug}.logs.>", account_public_key: account_key},
        %{subject: "#{slug}.events.>", account_public_key: account_key},
        %{subject: "#{slug}.otel.>", account_public_key: account_key}
      ]
    end)
  end

  defp update_platform_jwt(platform_tenant, account_jwt) do
    actor = SystemActor.platform(:nats_service_account)

    platform_tenant
    |> Ash.Changeset.for_update(:update_nats_account_jwt, %{account_jwt: account_jwt},
      actor: actor
    )
    |> Ash.update()
  end

  defp push_platform_jwt(platform_tenant, account_jwt) do
    account_key = platform_tenant.nats_account_public_key

    if is_binary(account_key) and account_key != "" do
      case AccountClient.push_account_jwt(account_key, account_jwt) do
        {:ok, %{success: true}} ->
          :ok

        {:ok, %{success: false, message: message}} ->
          Logger.warning("[NATS] Platform JWT push failed: #{message}")
          :ok

        {:error, reason} ->
          Logger.warning("[NATS] Platform JWT push error: #{inspect(reason)}")
          :ok
      end
    else
      {:error, :platform_public_key_missing}
    end
  end

  defp push_account_jwt(result) do
    case AccountClient.push_account_jwt(result.account_public_key, result.account_jwt) do
      {:ok, %{success: true}} -> :ok
      {:ok, %{success: false, message: message}} -> {:error, message}
      {:error, reason} -> {:error, reason}
    end
  end
end
