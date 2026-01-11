defmodule ServiceRadar.NATS.Workers.CreateAccountWorker do
  @moduledoc """
  Oban worker for asynchronously creating NATS accounts for tenants.

  This worker is triggered when a new tenant is created. It calls datasvc
  to generate the NATS account credentials and stores them encrypted
  in the tenant record.

  ## Retries

  The job will retry up to 5 times with exponential backoff. If all retries
  fail, the tenant's NATS account status is set to `:error`.

  ## Usage

      # Enqueue account creation for a tenant
      {:ok, _job} = CreateAccountWorker.enqueue(tenant_id)

      # Enqueue with options
      {:ok, _job} = CreateAccountWorker.enqueue(tenant_id,
        scheduled_at: DateTime.add(DateTime.utc_now(), 60, :second)
      )
  """

  use Oban.Worker,
    queue: :nats_accounts,
    max_attempts: 5,
    unique: [period: 60, keys: [:tenant_id]]

  require Ash.Query
  require Logger

  alias ServiceRadar.Identity.Tenant
  alias ServiceRadar.Events.JobWriter
  alias ServiceRadar.NATS.AccountClient

  # Only select fields needed for NATS account creation.
  # Explicitly excludes encrypted fields (contact_email, contact_name,
  # nats_account_seed_ciphertext) to prevent AshCloak decryption attempts.
  @tenant_select_fields [
    :id,
    :slug,
    :is_platform_tenant,
    :status,
    :plan,
    :nats_account_status,
    :nats_account_jwt,
    :nats_account_public_key
  ]

  @doc """
  Enqueue a NATS account creation job for a tenant.

  ## Options

    * `:scheduled_at` - Schedule the job for a specific time
    * `:priority` - Job priority (lower = higher priority)

  ## Examples

      {:ok, job} = CreateAccountWorker.enqueue(tenant_id)
      {:ok, job} = CreateAccountWorker.enqueue(tenant_id, scheduled_at: ~U[2025-01-01 00:00:00Z])
  """
  @spec enqueue(Ecto.UUID.t(), keyword()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(tenant_id, opts \\ []) do
    if oban_running?() do
      args = %{"tenant_id" => tenant_id}

      job_opts =
        []
        |> maybe_add_scheduled_at(opts[:scheduled_at])
        |> maybe_add_priority(opts[:priority])

      args
      |> new(job_opts)
      |> Oban.insert()
    else
      {:error, :oban_not_running}
    end
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"tenant_id" => tenant_id}, attempt: attempt, max_attempts: max} =
        job) do
    Logger.info("Creating NATS account for tenant #{tenant_id} (attempt #{attempt}/#{max})")

    with {:ok, tenant} <- get_tenant(tenant_id),
         :ok <- validate_tenant_status(tenant),
         {:ok, tenant} <- mark_pending(tenant),
         {:ok, result} <- create_nats_account(tenant),
         {:ok, tenant} <- store_account_credentials(tenant, result),
         :ok <- push_jwt_to_resolver(result),
         :ok <- maybe_update_platform_imports(tenant) do
      Logger.info("Successfully created NATS account for tenant #{tenant_id}")
      :ok
    else
      {:error, :tenant_not_found} ->
        Logger.error("Tenant #{tenant_id} not found, discarding job")
        {:discard, :tenant_not_found}

      {:error, :tenant_deleted} ->
        Logger.info("Tenant #{tenant_id} is deleted, discarding job")
        {:discard, :tenant_deleted}

      {:error, :account_already_ready} ->
        Logger.info("NATS account already ready for tenant #{tenant_id}")
        :ok

      {:error, {:grpc_error, message}} = error ->
        Logger.error("gRPC error creating NATS account for tenant #{tenant_id}: #{message}")

        if attempt >= max do
          mark_error(tenant_id, message)
          record_final_failure(job, tenant_id, message)
        end

        error

      {:error, :not_connected} = error ->
        Logger.warning("datasvc not connected, will retry for tenant #{tenant_id}")

        if attempt >= max do
          mark_error(tenant_id, "datasvc not connected")
          record_final_failure(job, tenant_id, :not_connected)
        end

        error

      {:error, reason} = error ->
        Logger.error("Error creating NATS account for tenant #{tenant_id}: #{inspect(reason)}")

        if attempt >= max do
          mark_error(tenant_id, inspect(reason))
          record_final_failure(job, tenant_id, reason)
        end

        error
    end
  end

  # Private helpers

  defp get_tenant(tenant_id) do
    # Use Ash.Query.select to only load fields we need.
    # This prevents AshCloak from attempting to decrypt encrypted fields
    # (contact_email, contact_name) which may be NULL.
    Tenant
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^tenant_id)
    |> Ash.Query.select(@tenant_select_fields)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, nil} -> {:error, :tenant_not_found}
      {:ok, tenant} -> {:ok, tenant}
      {:error, error} -> {:error, error}
    end
  end

  defp validate_tenant_status(tenant) do
    cond do
      tenant.status == :deleted ->
        {:error, :tenant_deleted}

      tenant.nats_account_status == :ready and tenant.nats_account_jwt != nil ->
        {:error, :account_already_ready}

      true ->
        :ok
    end
  end

  defp mark_pending(tenant) do
    tenant
    |> Ash.Changeset.for_update(:set_nats_account_pending, %{})
    |> Ash.update(authorize?: false)
  end

  defp create_nats_account(tenant) do
    # Build limits based on tenant plan
    limits = build_limits_for_plan(tenant.plan)

    case AccountClient.create_tenant_account(to_string(tenant.slug), limits: limits) do
      {:ok, result} = success ->
        Logger.debug(
          "NATS account created successfully: public_key=#{inspect(result.account_public_key)}, " <>
            "seed_len=#{result.account_seed && String.length(result.account_seed)}, " <>
            "jwt_len=#{result.account_jwt && String.length(result.account_jwt)}"
        )

        success

      {:error, _} = error ->
        error
    end
  end

  defp store_account_credentials(tenant, result) do
    Logger.debug(
      "Storing credentials: public_key=#{inspect(result.account_public_key)}, seed=present, jwt=present"
    )

    tenant
    |> Ash.Changeset.for_update(:set_nats_account, %{
      account_public_key: result.account_public_key,
      account_seed: result.account_seed,
      account_jwt: result.account_jwt
    })
    |> Ash.update(authorize?: false)
  end

  defp mark_error(tenant_id, message) do
    case get_tenant(tenant_id) do
      {:ok, tenant} ->
        tenant
        |> Ash.Changeset.for_update(:set_nats_account_error, %{error_message: message})
        |> Ash.update(authorize?: false)

        :ok

      {:error, _} ->
        :ok
    end
  end

  defp oban_running? do
    try do
      _ = Oban.Registry.config(Oban)
      true
    rescue
      _ -> false
    end
  end

  defp record_final_failure(%Oban.Job{} = job, tenant_id, reason) do
    if job.attempt >= job.max_attempts do
      message =
        "NATS account provisioning failed after #{job.attempt}/#{job.max_attempts} attempts"

      details = %{
        worker: job.worker,
        queue: job.queue,
        attempt: job.attempt,
        max_attempts: job.max_attempts
      }

      case JobWriter.write_failure(
             tenant_id: tenant_id,
             job_name: "nats.account.create",
             job_id: to_string(job.id),
             queue: job.queue,
             attempt: job.attempt,
             max_attempts: job.max_attempts,
             error: reason,
             details: details,
             message: message,
             severity: :high,
             log_name: "jobs.nats_account"
           ) do
        :ok ->
          :ok

        {:error, write_error} ->
          Logger.warning(
            "Failed to record NATS account job failure event: #{inspect(write_error)}"
          )
      end
    end
  end

  defp build_limits_for_plan(plan) do
    case plan do
      :free ->
        %{
          max_connections: 10,
          max_subscriptions: 100,
          max_payload_bytes: 1_048_576,
          max_data_bytes: 10_485_760,
          allow_wildcard_exports: true
        }

      :pro ->
        %{
          max_connections: 100,
          max_subscriptions: 1000,
          max_payload_bytes: 4_194_304,
          max_data_bytes: 104_857_600,
          allow_wildcard_exports: true
        }

      :enterprise ->
        # Enterprise has no enforced limits (uses defaults)
        nil

      _ ->
        # Default to free tier limits
        %{
          max_connections: 10,
          max_subscriptions: 100,
          max_payload_bytes: 1_048_576,
          max_data_bytes: 10_485_760,
          allow_wildcard_exports: true
        }
    end
  end

  defp maybe_add_scheduled_at(opts, nil), do: opts
  defp maybe_add_scheduled_at(opts, %DateTime{} = at), do: Keyword.put(opts, :scheduled_at, at)

  defp maybe_add_priority(opts, nil), do: opts
  defp maybe_add_priority(opts, priority), do: Keyword.put(opts, :priority, priority)

  defp push_jwt_to_resolver(result) do
    # Push the account JWT to the NATS resolver for immediate activation
    # This allows tenants to connect immediately without NATS restart
    Logger.debug("Pushing account JWT to NATS resolver for #{result.account_public_key}")

    case AccountClient.push_account_jwt(result.account_public_key, result.account_jwt) do
      {:ok, %{success: true}} ->
        Logger.info("Account JWT pushed to resolver successfully")
        :ok

      {:ok, %{success: false, message: message}} ->
        # JWT push failed, but account was created - log warning but don't fail the job
        # The JWT can be pushed again later or NATS server may pick it up on reload
        Logger.warning(
          "Failed to push JWT to resolver: #{message} - tenant will work after NATS reload"
        )

        :ok

      {:error, reason} ->
        # Connection error to datasvc - log but don't fail
        # The account is created and stored, just not immediately active
        Logger.warning(
          "Error pushing JWT to resolver: #{inspect(reason)} - tenant will work after NATS reload"
        )

        :ok
    end
  end

  defp maybe_update_platform_imports(%{is_platform_tenant: true}), do: :ok

  defp maybe_update_platform_imports(%{slug: slug}) do
    with {:ok, platform_tenant} <- get_platform_tenant(),
         :ok <- ensure_platform_account_ready(platform_tenant),
         {:ok, platform_seed} <- decrypt_account_seed(platform_tenant),
         {:ok, import_tenants} <- load_import_tenants(),
         imports <- build_stream_imports(import_tenants),
         {:ok, result} <-
           AccountClient.sign_account_jwt(
             to_string(platform_tenant.slug),
             platform_seed,
             imports: imports
           ),
         {:ok, _tenant} <- update_platform_jwt(platform_tenant, result.account_jwt),
         :ok <- push_platform_jwt(platform_tenant, result.account_jwt) do
      Logger.info("[NATS] Platform imports updated after provisioning #{slug}")
      :ok
    else
      {:error, :platform_missing} ->
        Logger.warning("[NATS] Platform tenant missing; skipping imports update")
        :ok

      {:error, :platform_not_ready} ->
        Logger.warning("[NATS] Platform account not ready; skipping imports update")
        :ok

      {:error, reason} ->
        Logger.warning("[NATS] Failed to update platform imports: #{inspect(reason)}")
        :ok
    end
  end

  defp get_platform_tenant do
    Tenant
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(is_platform_tenant == true)
    |> Ash.Query.select([
      :id,
      :slug,
      :nats_account_public_key,
      :nats_account_seed_ciphertext,
      :nats_account_status,
      :nats_account_jwt
    ])
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, nil} -> {:error, :platform_missing}
      {:ok, tenant} -> {:ok, tenant}
      {:error, error} -> {:error, error}
    end
  end

  defp ensure_platform_account_ready(platform_tenant) do
    if platform_tenant.nats_account_status == :ready and platform_tenant.nats_account_jwt != nil do
      :ok
    else
      {:error, :platform_not_ready}
    end
  end

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

  defp load_import_tenants do
    Tenant
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(
      status == :active and is_platform_tenant == false and nats_account_status == :ready and
        not is_nil(nats_account_public_key)
    )
    |> Ash.Query.select([:slug, :nats_account_public_key])
    |> Ash.read(authorize?: false)
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
    platform_tenant
    |> Ash.Changeset.for_update(:update_nats_account_jwt, %{account_jwt: account_jwt})
    |> Ash.update(authorize?: false)
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
end
