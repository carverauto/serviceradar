defmodule ServiceRadar.Edge.Workers.ProvisionAgentWorker do
  @moduledoc """
  Oban worker that mints per-agent NATS flow-collector credentials.

  This is the server-side mint step of B-5 sub-issue 1 (per-agent
  `nats.creds`). It mirrors `ServiceRadar.Edge.Workers.ProvisionCollectorWorker`
  but uses the agent-specific permission template defined in
  `ServiceRadar.NATS.AgentFlowCollectorPermissions`, which is the Elixir
  mirror of the Go helper `GenerateAgentFlowCollectorCreds` in
  `go/pkg/cli/nats_bootstrap.go`.

  ## Why mint server-side?

  The platform account seed is held only on core/Elixir (see
  `Application.get_env(:serviceradar, :nats_account_seed)`). Self-minting
  on the agent would require shipping the seed in the bundle, which
  inverts the current trust boundary and would let any compromised agent
  forge subjects for any other agent. Shipping a pre-signed `*.creds`
  file scoped to `flow.host-slice.<agent_id>` matches the established
  collector pattern and keeps the seed off the wire.

  ## Inputs

  Requires an `OnboardingPackage` whose `component_type` is `:agent` and
  whose `component_id` is a NATS-subject-safe token (the same character
  set that the Go side enforces via `isSafeSubjectToken/1`).

  ## Output

  On success, the package is updated via the `:attach_nats_creds` action
  with:

    * `nats_credential_id` - id of the new `NatsCredential` row used for
      revocation.
    * `nats_creds_ciphertext` - AshCloak-encrypted `.creds` file content
      ready to be tarred into the agent bundle on download.

  ## Retries

  Up to 5 attempts with exponential backoff via Oban defaults.
  """

  use Oban.Worker,
    queue: :nats_accounts,
    max_attempts: 5,
    unique: [period: :infinity, keys: [:package_id]]

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Edge.NatsCredential
  alias ServiceRadar.Edge.OnboardingPackage
  alias ServiceRadar.NATS.AccountClient
  alias ServiceRadar.NATS.AgentFlowCollectorPermissions
  alias ServiceRadar.Oban.Router

  require Ash.Query
  require Logger

  @doc """
  Enqueue a per-agent flow-collector creds provisioning job.

  ## Options

    * `:scheduled_at` - schedule the job for a specific time
    * `:priority` - job priority (lower = higher priority)
  """
  @spec enqueue(Ecto.UUID.t(), keyword()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(package_id, opts \\ []) do
    job_opts =
      []
      |> maybe_put(:scheduled_at, opts[:scheduled_at])
      |> maybe_put(:priority, opts[:priority])

    %{"package_id" => package_id}
    |> new(job_opts)
    |> Router.insert()
  end

  @impl Oban.Worker
  def perform(job), do: perform(job, [])

  @doc false
  def perform(
        %Oban.Job{args: %{"package_id" => package_id}, attempt: attempt, max_attempts: max},
        opts
      ) do
    account_client = Keyword.get(opts, :account_client, AccountClient)

    Logger.info(
      "Provisioning flow-collector NATS creds for agent package #{package_id} " <>
        "(attempt #{attempt}/#{max})"
    )

    with {:ok, package} <- get_package(package_id),
         :ok <- validate_agent_package(package),
         {:ok, agent_id} <- resolve_agent_id(package),
         {:ok, permissions} <- build_permissions(agent_id),
         {:ok, nats_config} <- get_nats_config(),
         {:ok, user_creds} <- mint_credentials(nats_config, agent_id, permissions, account_client),
         {:ok, credential} <- create_credential_record(package, agent_id, user_creds),
         {:ok, _package} <- attach_creds(package, credential.id, user_creds.creds_file_content) do
      Logger.info(
        "Provisioned flow-collector NATS creds for agent package #{package_id} (agent_id=#{agent_id})"
      )

      :ok
    else
      {:error, :package_not_found} ->
        Logger.error("Agent package #{package_id} not found, discarding job")
        {:discard, :package_not_found}

      {:error, :not_agent_package} ->
        Logger.info(
          "Package #{package_id} is not an agent package, discarding flow-collector creds job"
        )

        {:discard, :not_agent_package}

      {:error, :invalid_agent_id} ->
        Logger.error("Agent package #{package_id} has an invalid agent_id for NATS subjects")
        {:discard, :invalid_agent_id}

      {:error, :nats_not_configured} ->
        Logger.error("NATS account not configured for agent package #{package_id}")
        {:discard, :nats_not_configured}

      {:error, :account_seed_not_found} ->
        Logger.error("NATS account seed not configured for agent package #{package_id}")
        {:discard, :account_seed_not_found}

      {:error, {:grpc_error, message}} = error ->
        Logger.error(
          "gRPC error provisioning flow-collector creds for agent #{package_id}: #{message}"
        )

        error

      {:error, :not_connected} = error ->
        Logger.warning("datasvc not connected, will retry agent package #{package_id}")
        error

      {:error, reason} = error ->
        Logger.error(
          "Error provisioning flow-collector creds for agent #{package_id}: #{inspect(reason)}"
        )

        error
    end
  end

  # Public helper so callers (controllers, the deliver flow, the future
  # rotation worker) can use the same permission build path as the worker
  # without duplicating the safety check.
  @doc false
  @spec build_permissions(String.t()) ::
          {:ok, AgentFlowCollectorPermissions.permissions()} | {:error, :invalid_agent_id}
  def build_permissions(agent_id), do: AgentFlowCollectorPermissions.permissions(agent_id)

  # ----- Internal helpers -----

  defp get_package(package_id) do
    actor = SystemActor.system(:provision_agent)

    case OnboardingPackage
         |> Ash.Query.for_read(:read)
         |> Ash.Query.filter(id == ^package_id)
         |> Ash.read_one(actor: actor) do
      {:ok, nil} -> {:error, :package_not_found}
      {:ok, package} -> {:ok, package}
      {:error, error} -> {:error, error}
    end
  end

  defp validate_agent_package(%OnboardingPackage{component_type: :agent}), do: :ok
  defp validate_agent_package(_), do: {:error, :not_agent_package}

  defp resolve_agent_id(%OnboardingPackage{component_id: id}) when is_binary(id) and id != "" do
    if AgentFlowCollectorPermissions.safe_subject_token?(id) do
      {:ok, id}
    else
      {:error, :invalid_agent_id}
    end
  end

  defp resolve_agent_id(_), do: {:error, :invalid_agent_id}

  defp get_nats_config do
    account_name = Application.get_env(:serviceradar, :nats_account_name)
    account_seed = Application.get_env(:serviceradar, :nats_account_seed)

    cond do
      is_nil(account_name) or account_name == "" -> {:error, :nats_not_configured}
      is_nil(account_seed) or account_seed == "" -> {:error, :account_seed_not_found}
      true -> {:ok, %{account_name: account_name, account_seed: account_seed}}
    end
  end

  defp mint_credentials(nats_config, agent_id, permissions, account_client) do
    account_client.generate_user_credentials(
      nats_config.account_name,
      nats_config.account_seed,
      AgentFlowCollectorPermissions.user_name(agent_id),
      :service,
      permissions: permissions,
      expiration_seconds: expiration_seconds()
    )
  end

  defp expiration_seconds do
    # 30 day default (in seconds). Override via app env if needed; the
    # rotation worker (sub-issue follow-up) re-mints well before this
    # expires.
    Application.get_env(
      :serviceradar,
      :agent_flow_collector_creds_expiration_seconds,
      30 * 24 * 60 * 60
    )
  end

  defp create_credential_record(package, agent_id, user_creds) do
    actor = SystemActor.system(:provision_agent)

    NatsCredential
    |> Ash.Changeset.for_create(
      :create,
      %{
        user_name: AgentFlowCollectorPermissions.user_name(agent_id),
        credential_type: :service,
        expires_at: user_creds.expires_at,
        metadata: %{
          purpose: "agent-flow-collector",
          agent_id: agent_id,
          partition_id: package.partition_id,
          site: package.site
        },
        user_public_key: user_creds.user_public_key,
        onboarding_package_id: package.id
      },
      actor: actor
    )
    |> Ash.create()
  end

  defp attach_creds(package, credential_id, creds_content) do
    actor = SystemActor.system(:provision_agent)

    package
    |> Ash.Changeset.for_update(
      :attach_nats_creds,
      %{
        nats_credential_id: credential_id,
        nats_creds_content: creds_content
      },
      actor: actor
    )
    |> Ash.update()
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
