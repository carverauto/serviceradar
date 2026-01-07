defmodule ServiceRadar.Edge.Workers.ProvisionCollectorWorker do
  @moduledoc """
  Oban worker for provisioning NATS credentials for collector packages.

  This worker is triggered when a new collector package is created. It:
  1. Verifies the tenant's NATS account is ready
  2. Decrypts the tenant's account seed
  3. Calls datasvc to generate user credentials with collector-specific permissions
  4. Creates the NatsCredential record
  5. Updates the CollectorPackage status to ready

  ## Retries

  The job will retry up to 5 times with exponential backoff. If all retries
  fail, the collector package status is set to `:failed`.

  ## Usage

      # Enqueue provisioning for a collector package
      {:ok, _job} = ProvisionCollectorWorker.enqueue(package_id)
  """

  use Oban.Worker,
    queue: :nats_accounts,
    max_attempts: 5,
    unique: [period: 60, keys: [:package_id]]

  require Ash.Query
  require Logger

  alias ServiceRadar.Cluster.TenantSchemas
  alias ServiceRadar.Edge.CollectorPackage
  alias ServiceRadar.Edge.NatsCredential
  alias ServiceRadar.Edge.TenantCA
  alias ServiceRadar.Identity.Tenant
  alias ServiceRadar.NATS.AccountClient
  alias ServiceRadar.Oban.Router

  @doc """
  Enqueue a credential provisioning job for a collector package.

  ## Options

    * `:scheduled_at` - Schedule the job for a specific time
    * `:priority` - Job priority (lower = higher priority)

  ## Examples

      {:ok, job} = ProvisionCollectorWorker.enqueue(package_id)
  """
  @spec enqueue(Ecto.UUID.t(), keyword()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(package_id, opts \\ []) do
    tenant_schema = tenant_schema_from_opts(opts)

    args =
      %{"package_id" => package_id}
      |> maybe_put_arg("tenant_schema", tenant_schema)

    job_opts =
      []
      |> maybe_add_scheduled_at(opts[:scheduled_at])
      |> maybe_add_priority(opts[:priority])

    args
    |> new(job_opts)
    |> Router.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"package_id" => package_id} = args, attempt: attempt, max_attempts: max}) do
    Logger.info("Provisioning credentials for collector package #{package_id} (attempt #{attempt}/#{max})")

    tenant_schema = tenant_schema_from_args(args)

    with {:ok, tenant_schema} <- require_tenant_schema(tenant_schema, package_id),
         {:ok, package} <- get_package(package_id, tenant_schema),
         :ok <- validate_package_status(package),
         {:ok, _package} <- mark_provisioning(package, tenant_schema),
         {:ok, tenant} <- get_tenant(package.tenant_id),
         :ok <- validate_tenant_nats_ready(tenant),
         {:ok, account_seed} <- get_account_seed(tenant),
         {:ok, user_creds} <- generate_user_credentials(tenant, package, account_seed),
         {:ok, tenant_ca} <- get_tenant_ca(tenant, tenant_schema),
         {:ok, tls_certs} <- generate_tls_certificates(tenant_ca, package),
         {:ok, credential} <- create_credential_record(package, user_creds, tenant_schema),
         {:ok, _package} <-
           mark_ready(package, credential.id, user_creds.creds_file_content, tls_certs, tenant_schema) do
      Logger.info("Successfully provisioned credentials for collector package #{package_id}")
      :ok
    else
      {:error, :tenant_schema_not_found} ->
        Logger.error("Tenant schema not found for collector package #{package_id}, discarding job")
        {:discard, :tenant_schema_not_found}

      {:error, :package_not_found} ->
        Logger.error("Collector package #{package_id} not found, discarding job")
        {:discard, :package_not_found}

      {:error, :package_not_pending} ->
        Logger.info("Collector package #{package_id} not in pending state, skipping")
        :ok

      {:error, :tenant_not_found} ->
        Logger.error("Tenant not found for package #{package_id}, discarding job")
        mark_failed(package_id, tenant_schema, "Tenant not found")
        {:discard, :tenant_not_found}

      {:error, :tenant_nats_not_ready} ->
        Logger.warning("Tenant NATS account not ready for package #{package_id}, will retry")
        {:error, :tenant_nats_not_ready}

      {:error, :account_seed_not_found} ->
        Logger.error("Tenant account seed not found for package #{package_id}")
        mark_failed(package_id, tenant_schema, "Tenant NATS account seed not configured")
        {:discard, :account_seed_not_found}

      {:error, :tenant_ca_not_found} ->
        Logger.error("Tenant CA not found for package #{package_id}")
        mark_failed(package_id, tenant_schema, "Tenant certificate authority not configured")
        {:discard, :tenant_ca_not_found}

      {:error, :tenant_ca_key_decrypt_failed} ->
        Logger.error("Failed to decrypt tenant CA key for package #{package_id}")
        mark_failed(package_id, tenant_schema, "Failed to decrypt tenant CA key")
        {:discard, :tenant_ca_key_decrypt_failed}

      {:error, {:tls_cert_generation_failed, reason}} = error ->
        Logger.error("TLS certificate generation failed for package #{package_id}: #{inspect(reason)}")

        if attempt >= max do
          mark_failed(package_id, tenant_schema, "TLS certificate generation failed: #{inspect(reason)}")
        end

        error

      {:error, {:grpc_error, message}} = error ->
        Logger.error("gRPC error provisioning credentials for package #{package_id}: #{message}")

        if attempt >= max do
          mark_failed(package_id, tenant_schema, message)
        end

        error

      {:error, :not_connected} = error ->
        Logger.warning("datasvc not connected, will retry for package #{package_id}")
        error

      {:error, reason} = error ->
        Logger.error("Error provisioning credentials for package #{package_id}: #{inspect(reason)}")

        if attempt >= max do
          mark_failed(package_id, tenant_schema, inspect(reason))
        end

        error
    end
  end

  # Private helpers

  defp get_package(package_id, tenant_schema) do
    case CollectorPackage
         |> Ash.Query.for_read(:read)
         |> Ash.Query.set_tenant(tenant_schema)
         |> Ash.Query.filter(id == ^package_id)
         |> Ash.read_one(authorize?: false) do
      {:ok, nil} -> {:error, :package_not_found}
      {:ok, package} -> {:ok, package}
      {:error, error} -> {:error, error}
    end
  end

  defp validate_package_status(package) do
    if package.status in [:pending, :provisioning] do
      :ok
    else
      {:error, :package_not_pending}
    end
  end

  defp mark_provisioning(package, tenant_schema) do
    package
    |> Ash.Changeset.for_update(:provision, %{}, tenant: tenant_schema)
    |> Ash.update(authorize?: false)
  end

  defp get_tenant(tenant_id) do
    case Tenant
         |> Ash.Query.for_read(:read)
         |> Ash.Query.filter(id == ^tenant_id)
         |> Ash.read_one(authorize?: false) do
      {:ok, nil} -> {:error, :tenant_not_found}
      {:ok, tenant} -> {:ok, tenant}
      {:error, error} -> {:error, error}
    end
  end

  defp validate_tenant_nats_ready(tenant) do
    if tenant.nats_account_status == :ready and tenant.nats_account_jwt != nil do
      :ok
    else
      {:error, :tenant_nats_not_ready}
    end
  end

  defp get_account_seed(tenant) do
    # The nats_account_seed_ciphertext is encrypted via AshCloak
    # Since it's not in decrypt_by_default, we decrypt it via the Vault
    case tenant.nats_account_seed_ciphertext do
      nil ->
        {:error, :account_seed_not_found}

      encrypted_value when is_binary(encrypted_value) ->
        case ServiceRadar.Vault.decrypt(encrypted_value) do
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

  defp generate_user_credentials(tenant, package, account_seed) do
    # Build permissions based on collector type
    permissions = build_permissions_for_collector(package.collector_type, tenant.slug)

    AccountClient.generate_user_credentials(
      to_string(tenant.slug),
      account_seed,
      package.user_name,
      :collector,
      permissions: permissions
    )
  end

  defp build_permissions_for_collector(collector_type, _tenant_slug) do
    # Collectors publish to simple subjects without tenant prefix.
    # NATS Account subject mapping transforms these to tenant-prefixed subjects
    # on the server side (e.g., "syslog.>" -> "{tenant}.syslog.>").
    # This keeps collectors tenant-unaware while NATS enforces isolation.

    case collector_type do
      :flowgger ->
        %{
          publish_allow: ["syslog.>", "events.syslog.>"],
          subscribe_allow: []
        }

      :trapd ->
        %{
          publish_allow: ["snmp.traps.>", "events.snmp.>"],
          subscribe_allow: []
        }

      :netflow ->
        %{
          publish_allow: ["netflow.>", "events.netflow.>"],
          subscribe_allow: []
        }

      :otel ->
        %{
          publish_allow: [
            "otel.traces.>",
            "otel.metrics.>",
            "otel.logs.>",
            "events.otel.>"
          ],
          subscribe_allow: []
        }

      _ ->
        %{
          publish_allow: ["events.>"],
          subscribe_allow: []
        }
    end
  end

  defp create_credential_record(package, user_creds, tenant_schema) do
    NatsCredential
    |> Ash.Changeset.for_create(:create, %{
      user_name: package.user_name,
      credential_type: :collector,
      collector_type: package.collector_type,
      expires_at: user_creds.expires_at,
      metadata: %{
        site: package.site,
        hostname: package.hostname
      }
    }, tenant: tenant_schema)
    |> Ash.Changeset.set_argument(:user_public_key, user_creds.user_public_key)
    |> Ash.Changeset.set_argument(:onboarding_package_id, nil)
    |> Ash.Changeset.change_attribute(:tenant_id, package.tenant_id)
    |> Ash.create(authorize?: false)
  end

  defp get_tenant_ca(tenant, tenant_schema) do
    case TenantCA
         |> Ash.Query.for_read(:active)
         |> Ash.Query.set_tenant(tenant_schema)
         |> Ash.Query.filter(tenant_id == ^tenant.id)
         |> Ash.read_one(authorize?: false) do
      {:ok, nil} -> {:error, :tenant_ca_not_found}
      {:ok, ca} -> {:ok, ca}
      {:error, error} -> {:error, error}
    end
  end

  defp generate_tls_certificates(tenant_ca, package) do
    # Decrypt the tenant CA's private key
    case tenant_ca.private_key_pem do
      nil ->
        {:error, :tenant_ca_key_decrypt_failed}

      encrypted_value when is_binary(encrypted_value) ->
        case ServiceRadar.Vault.decrypt(encrypted_value) do
          {:ok, private_key_pem} when is_binary(private_key_pem) and private_key_pem != "" ->
            # Build CA data map for the generator
            ca_data = %{
              tenant_id: tenant_ca.tenant_id,
              certificate_pem: tenant_ca.certificate_pem,
              private_key_pem: private_key_pem
            }

            # Generate component certificate
            component_id = "#{package.collector_type}-#{short_id(package.id)}"
            partition_id = package.site || "default"

            case TenantCA.Generator.generate_component_cert(
                   ca_data,
                   component_id,
                   :collector,
                   partition_id,
                   validity_days: 365
                 ) do
              {:ok, cert_data} ->
                {:ok, cert_data}

              {:error, reason} ->
                {:error, {:tls_cert_generation_failed, reason}}
            end

          {:ok, _} ->
            {:error, :tenant_ca_key_decrypt_failed}

          {:error, _reason} ->
            {:error, :tenant_ca_key_decrypt_failed}
        end

      _ ->
        {:error, :tenant_ca_key_decrypt_failed}
    end
  end

  defp short_id(id) when is_binary(id), do: String.slice(id, 0, 8)

  defp mark_ready(package, credential_id, nats_creds_content, tls_certs, tenant_schema) do
    package
    |> Ash.Changeset.for_update(:ready, %{}, tenant: tenant_schema)
    |> Ash.Changeset.set_argument(:nats_credential_id, credential_id)
    |> Ash.Changeset.set_argument(:nats_creds_content, nats_creds_content)
    |> Ash.Changeset.set_argument(:tls_cert_pem, tls_certs.certificate_pem)
    |> Ash.Changeset.set_argument(:tls_key_pem, tls_certs.private_key_pem)
    |> Ash.Changeset.set_argument(:ca_chain_pem, tls_certs.ca_chain_pem)
    |> Ash.update(authorize?: false)
  end

  defp mark_failed(package_id, tenant_schema, message) do
    case get_package(package_id, tenant_schema) do
      {:ok, package} ->
        package
        |> Ash.Changeset.for_update(:fail, %{}, tenant: tenant_schema)
        |> Ash.Changeset.set_argument(:error_message, message)
        |> Ash.update(authorize?: false)

      _ ->
        :ok
    end
  end

  defp maybe_add_scheduled_at(opts, nil), do: opts
  defp maybe_add_scheduled_at(opts, %DateTime{} = at), do: Keyword.put(opts, :scheduled_at, at)

  defp maybe_add_priority(opts, nil), do: opts
  defp maybe_add_priority(opts, priority), do: Keyword.put(opts, :priority, priority)

  defp maybe_put_arg(args, _key, nil), do: args
  defp maybe_put_arg(args, key, value), do: Map.put(args, key, value)

  defp tenant_schema_from_opts(opts) do
    cond do
      schema = Keyword.get(opts, :tenant_schema) ->
        schema

      tenant = Keyword.get(opts, :tenant) ->
        TenantSchemas.schema_for_tenant(tenant)

      tenant_id = Keyword.get(opts, :tenant_id) ->
        TenantSchemas.schema_for_id(tenant_id)

      true ->
        nil
    end
  end

  defp tenant_schema_from_args(args) do
    cond do
      schema = Map.get(args, "tenant_schema") ->
        schema

      tenant = Map.get(args, "tenant") ->
        TenantSchemas.schema_for_tenant(tenant)

      tenant_id = Map.get(args, "tenant_id") ->
        TenantSchemas.schema_for_id(tenant_id)

      true ->
        nil
    end
  end

  defp require_tenant_schema(nil, _package_id), do: {:error, :tenant_schema_not_found}
  defp require_tenant_schema(schema, _package_id), do: {:ok, schema}
end
