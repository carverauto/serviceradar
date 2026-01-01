defmodule ServiceRadar.NATS.OperatorBootstrap do
  @moduledoc """
  Auto-bootstrap NATS operator on application startup.

  This GenServer runs once at startup to ensure the NATS operator is initialized.
  It checks if an operator record exists in the database, and if not, bootstraps
  the operator using the NATS_OPERATOR_SEED environment variable.

  ## Configuration

  - `NATS_OPERATOR_SEED` - The operator seed to use for signing account JWTs.
    If not set, auto-bootstrap is skipped.
  - `NATS_AUTO_BOOTSTRAP` - Set to "false" to disable auto-bootstrap (default: "true")

  ## Bootstrap Flow

  1. Check if NatsOperator record exists in database
  2. If not, call datasvc BootstrapOperator RPC
  3. Store operator record (public key, JWT, system account info)
  4. Create NATS account for default tenant (if not already created)
  5. Log success or failure

  After bootstrap, new tenants can be onboarded without any manual steps.
  """

  use GenServer

  require Logger

  alias ServiceRadar.Identity.Tenant
  alias ServiceRadar.Infrastructure.NatsOperator
  alias ServiceRadar.NATS.AccountClient
  alias ServiceRadar.NATS.Workers.CreateAccountWorker

  @default_operator_name "serviceradar"

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    # Run bootstrap check asynchronously to not block app startup
    if auto_bootstrap_enabled?() do
      # Give datasvc time to be ready (it's started as a separate service)
      Process.send_after(self(), :check_and_bootstrap, 5_000)
      {:ok, %{status: :pending}}
    else
      Logger.debug("[NATS Bootstrap] Auto-bootstrap disabled")
      {:ok, %{status: :disabled}}
    end
  end

  @impl true
  def handle_info(:check_and_bootstrap, state) do
    new_state = do_bootstrap_check()
    {:noreply, Map.merge(state, new_state)}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # Public API

  @doc """
  Get the current bootstrap status.
  """
  def status do
    GenServer.call(__MODULE__, :status)
  catch
    :exit, _ -> {:error, :not_running}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, {:ok, state}, state}
  end

  # Private functions

  defp auto_bootstrap_enabled? do
    # Auto-bootstrap is enabled by default when datasvc is available.
    # Set NATS_AUTO_BOOTSTRAP=false to disable.
    # The NATS_OPERATOR_SEED only needs to be on datasvc (not core-elx)
    # since datasvc handles all cryptographic operations.
    case System.get_env("NATS_AUTO_BOOTSTRAP") do
      "false" -> false
      "0" -> false
      "no" -> false
      # Default to true - datasvc will have the seed configured
      _ -> true
    end
  end

  defp do_bootstrap_check do
    Logger.info("[NATS Bootstrap] Checking operator initialization status...")

    case get_current_operator() do
      {:ok, operator} ->
        Logger.info(
          "[NATS Bootstrap] Operator already initialized: #{operator.name} (#{operator.public_key})"
        )

        # Even if operator is already initialized, ensure default tenant has NATS account
        ensure_default_tenant_nats_account()

        %{status: :already_initialized, operator: operator}

      {:error, :not_found} ->
        Logger.info("[NATS Bootstrap] No operator found, attempting auto-bootstrap...")
        do_bootstrap()

      {:error, reason} ->
        Logger.error("[NATS Bootstrap] Error checking operator: #{inspect(reason)}")
        # Retry after delay
        Process.send_after(self(), :check_and_bootstrap, 30_000)
        %{status: :error, error: reason}
    end
  end

  defp do_bootstrap do
    operator_name = System.get_env("NATS_OPERATOR_NAME", @default_operator_name)

    # Call datasvc to bootstrap the operator
    # The NATS_OPERATOR_SEED is already set on datasvc, so it will use that
    opts = [
      operator_name: operator_name,
      generate_system_account: true
    ]

    case AccountClient.bootstrap_operator(opts) do
      {:ok, result} ->
        Logger.info(
          "[NATS Bootstrap] Operator bootstrapped successfully: #{result.operator_public_key}"
        )

        # Store operator record in database
        case create_operator_record(operator_name, result) do
          {:ok, operator} ->
            Logger.info("[NATS Bootstrap] Operator record stored in database")
            broadcast_operator_ready(operator)
            %{status: :bootstrapped, operator: operator}

          {:error, reason} ->
            Logger.error("[NATS Bootstrap] Failed to store operator record: #{inspect(reason)}")
            %{status: :error, error: reason}
        end

      {:error, {:grpc_error, message}} when is_binary(message) ->
        if String.contains?(message, "already") do
          # Operator already bootstrapped in datasvc
          Logger.info("[NATS Bootstrap] Operator already exists in datasvc: #{message}")
          sync_operator_from_datasvc(operator_name)
        else
          Logger.error("[NATS Bootstrap] gRPC error: #{message}")
          Process.send_after(self(), :check_and_bootstrap, 30_000)
          %{status: :error, error: message}
        end

      {:error, reason} ->
        Logger.error("[NATS Bootstrap] Failed to bootstrap operator: #{inspect(reason)}")
        # Retry after delay
        Process.send_after(self(), :check_and_bootstrap, 30_000)
        %{status: :error, error: reason}
    end
  end

  defp sync_operator_from_datasvc(operator_name) do
    # Operator exists in datasvc but not in our database
    # Get operator info and create record
    case AccountClient.get_operator_info() do
      {:ok, info} when info.is_initialized ->
        case create_operator_record_from_info(operator_name, info) do
          {:ok, operator} ->
            Logger.info("[NATS Bootstrap] Synced operator from datasvc to database")
            broadcast_operator_ready(operator)
            %{status: :synced, operator: operator}

          {:error, reason} ->
            Logger.error("[NATS Bootstrap] Failed to create operator record: #{inspect(reason)}")
            %{status: :error, error: reason}
        end

      {:ok, _info} ->
        Logger.error("[NATS Bootstrap] Datasvc reports operator not initialized")
        %{status: :error, error: :not_initialized}

      {:error, reason} ->
        Logger.error("[NATS Bootstrap] Failed to get operator info: #{inspect(reason)}")
        %{status: :error, error: reason}
    end
  end

  defp get_current_operator do
    case NatsOperator
         |> Ash.Query.for_read(:get_current)
         |> Ash.Query.limit(1)
         |> Ash.read_one(authorize?: false) do
      {:ok, nil} -> {:error, :not_found}
      {:ok, operator} -> {:ok, operator}
      {:error, error} -> {:error, error}
    end
  end

  defp create_operator_record(name, result) do
    NatsOperator
    |> Ash.Changeset.for_create(:bootstrap, %{
      name: name,
      public_key: result.operator_public_key,
      operator_jwt: result.operator_jwt,
      system_account_public_key: result.system_account_public_key
    })
    |> Ash.create(authorize?: false)
  end

  defp create_operator_record_from_info(name, info) do
    # Note: GetOperatorInfoResponse includes operator_public_key, operator_name,
    # is_initialized, and system_account_public_key. The operator_jwt is not
    # available from this endpoint (only from BootstrapOperator).
    NatsOperator
    |> Ash.Changeset.for_create(:bootstrap, %{
      name: name,
      public_key: info.operator_public_key,
      operator_jwt: nil,
      system_account_public_key: info.system_account_public_key
    })
    |> Ash.create(authorize?: false)
  end

  defp broadcast_operator_ready(operator) do
    Phoenix.PubSub.broadcast(
      ServiceRadar.PubSub,
      "nats:operator",
      {:operator_ready, operator}
    )

    # After operator is ready, ensure default tenant has NATS account
    ensure_default_tenant_nats_account()
  end

  defp ensure_default_tenant_nats_account do
    # Find tenants that need NATS accounts (don't have one yet or not ready)
    Logger.info("[NATS Bootstrap] Checking for tenants needing NATS accounts...")

    case get_tenants_needing_nats_accounts() do
      {:ok, []} ->
        Logger.info("[NATS Bootstrap] All existing tenants have NATS accounts")

      {:ok, tenants} ->
        Logger.info("[NATS Bootstrap] Found #{length(tenants)} tenant(s) needing NATS accounts")

        if oban_running?() do
          for tenant <- tenants do
            Logger.info("[NATS Bootstrap] Creating NATS account for tenant: #{tenant.slug} (#{tenant.id})")

            case CreateAccountWorker.enqueue(tenant.id) do
              {:ok, _job} ->
                Logger.info("[NATS Bootstrap] Enqueued NATS account creation for #{tenant.slug}")

              {:error, reason} ->
                Logger.error(
                  "[NATS Bootstrap] Failed to enqueue NATS account for #{tenant.slug}: #{inspect(reason)}"
                )
            end
          end
        else
          Logger.warning(
            "[NATS Bootstrap] Oban not running; skipping NATS account provisioning"
          )
        end

      {:error, reason} ->
        Logger.error("[NATS Bootstrap] Error checking tenants: #{inspect(reason)}")
    end
  end

  defp oban_running? do
    Process.whereis(Oban) != nil
  end

  defp get_tenants_needing_nats_accounts do
    require Ash.Query

    # Find all active tenants that don't have a ready NATS account
    # Use :for_nats_provisioning action to avoid AshCloak decryption issues
    # when encrypted columns are NULL
    Tenant
    |> Ash.Query.for_read(:for_nats_provisioning)
    |> Ash.Query.filter(
      status == :active and (is_nil(nats_account_status) or nats_account_status != :ready)
    )
    |> Ash.read(authorize?: false)
  end
end
