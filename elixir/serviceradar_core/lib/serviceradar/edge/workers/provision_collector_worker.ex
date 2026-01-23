defmodule ServiceRadar.Edge.Workers.ProvisionCollectorWorker do
  @moduledoc """
  Oban worker for provisioning NATS credentials for collector packages.

  In single-deployment mode:
  - NATS account configuration comes from environment variables
  - TLS certificates are handled by external infrastructure (SPIFFE/SPIRE, cert-manager)
  - The worker generates NATS user credentials via datasvc gRPC

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

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Edge.CollectorPackage
  alias ServiceRadar.Edge.NatsCredential
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
    job_opts =
      []
      |> maybe_add_scheduled_at(opts[:scheduled_at])
      |> maybe_add_priority(opts[:priority])

    %{"package_id" => package_id}
    |> new(job_opts)
    |> Router.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"package_id" => package_id}, attempt: attempt, max_attempts: max}) do
    Logger.info(
      "Provisioning credentials for collector package #{package_id} (attempt #{attempt}/#{max})"
    )

    # In single-deployment mode, NATS config comes from environment
    with {:ok, package} <- get_package(package_id),
         :ok <- validate_package_status(package),
         {:ok, _package} <- mark_provisioning(package),
         {:ok, nats_config} <- get_nats_config(),
         {:ok, user_creds} <- generate_user_credentials(nats_config, package),
         {:ok, credential} <- create_credential_record(package, user_creds),
         {:ok, _package} <- mark_ready(package, credential.id, user_creds.creds_file_content) do
      Logger.info("Successfully provisioned credentials for collector package #{package_id}")
      :ok
    else
      {:error, :package_not_found} ->
        Logger.error("Collector package #{package_id} not found, discarding job")
        {:discard, :package_not_found}

      {:error, :package_not_pending} ->
        Logger.info("Collector package #{package_id} not in pending state, skipping")
        :ok

      {:error, :nats_not_configured} ->
        Logger.error("NATS not configured for package #{package_id}")
        mark_failed(package_id, "NATS account not configured for this deployment")
        {:discard, :nats_not_configured}

      {:error, :account_seed_not_found} ->
        Logger.error("NATS account seed not found for package #{package_id}")
        mark_failed(package_id, "NATS account seed not configured")
        {:discard, :account_seed_not_found}

      {:error, {:grpc_error, message}} = error ->
        Logger.error("gRPC error provisioning credentials for package #{package_id}: #{message}")

        if attempt >= max do
          mark_failed(package_id, message)
        end

        error

      {:error, :not_connected} = error ->
        Logger.warning("datasvc not connected, will retry for package #{package_id}")
        error

      {:error, reason} = error ->
        Logger.error(
          "Error provisioning credentials for package #{package_id}: #{inspect(reason)}"
        )

        if attempt >= max do
          mark_failed(package_id, inspect(reason))
        end

        error
    end
  end

  # Private helpers

  defp get_package(package_id) do
    actor = SystemActor.system(:provision_collector)

    case CollectorPackage
         |> Ash.Query.for_read(:read)
         |> Ash.Query.filter(id == ^package_id)
         |> Ash.read_one(actor: actor) do
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

  defp mark_provisioning(package) do
    actor = SystemActor.system(:provision_collector)

    package
    |> Ash.Changeset.for_update(:provision, %{}, actor: actor)
    |> Ash.update()
  end

  defp get_nats_config do
    # In single-deployment mode, NATS configuration comes from environment
    account_name = Application.get_env(:serviceradar, :nats_account_name)
    account_seed = Application.get_env(:serviceradar, :nats_account_seed)

    cond do
      is_nil(account_name) or account_name == "" ->
        {:error, :nats_not_configured}

      is_nil(account_seed) or account_seed == "" ->
        {:error, :account_seed_not_found}

      true ->
        {:ok, %{account_name: account_name, account_seed: account_seed}}
    end
  end

  defp generate_user_credentials(nats_config, package) do
    # Build permissions based on collector type
    permissions = build_permissions_for_collector(package.collector_type)

    AccountClient.generate_user_credentials(
      nats_config.account_name,
      nats_config.account_seed,
      package.user_name,
      :collector,
      permissions: permissions
    )
  end

  defp build_permissions_for_collector(collector_type) do
    # Collectors publish to simple subjects without any deployment prefix.
    # NATS account isolation enforces separation without subject rewriting.

    case collector_type do
      :flowgger ->
        %{
          publish_allow: ["logs.syslog.>"],
          subscribe_allow: []
        }

      :trapd ->
        %{
          publish_allow: ["logs.snmp.>"],
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
            "logs.otel"
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

  defp create_credential_record(package, user_creds) do
    actor = SystemActor.system(:provision_collector)

    NatsCredential
    |> Ash.Changeset.for_create(
      :create,
      %{
        user_name: package.user_name,
        credential_type: :collector,
        collector_type: package.collector_type,
        expires_at: user_creds.expires_at,
        metadata: %{
          site: package.site,
          hostname: package.hostname
        }
      }, actor: actor)
    |> Ash.Changeset.set_argument(:user_public_key, user_creds.user_public_key)
    |> Ash.Changeset.set_argument(:onboarding_package_id, nil)
    |> Ash.create()
  end

  defp mark_ready(package, credential_id, nats_creds_content) do
    # In single-deployment mode, TLS certificates are handled by external infrastructure
    # (SPIFFE/SPIRE, cert-manager). We only set the NATS credentials.
    actor = SystemActor.system(:provision_collector)

    package
    |> Ash.Changeset.for_update(:ready, %{}, actor: actor)
    |> Ash.Changeset.set_argument(:nats_credential_id, credential_id)
    |> Ash.Changeset.set_argument(:nats_creds_content, nats_creds_content)
    |> Ash.update()
  end

  defp mark_failed(package_id, message) do
    case get_package(package_id) do
      {:ok, package} ->
        actor = SystemActor.system(:provision_collector)

        package
        |> Ash.Changeset.for_update(:fail, %{}, actor: actor)
        |> Ash.Changeset.set_argument(:error_message, message)
        |> Ash.update()

      _ ->
        :ok
    end
  end

  defp maybe_add_scheduled_at(opts, nil), do: opts
  defp maybe_add_scheduled_at(opts, %DateTime{} = at), do: Keyword.put(opts, :scheduled_at, at)

  defp maybe_add_priority(opts, nil), do: opts
  defp maybe_add_priority(opts, priority), do: Keyword.put(opts, :priority, priority)
end
