defmodule ServiceRadar.NATS.AccountClient do
  @moduledoc """
  gRPC client for the datasvc NATSAccountService.

  This client is used to create and manage NATS accounts for tenant isolation.
  The datasvc is stateless - it only holds the operator key for signing JWTs.
  Account state (seeds, JWTs) is stored by Elixir in CNPG with AshCloak encryption.

  ## Configuration

  Uses the same configuration as DataService.Client since both services
  run on the same datasvc endpoint.

      config :serviceradar_core, ServiceRadar.DataService.Client,
        host: "datasvc",
        port: 50057,
        ssl: true,
        cert_dir: "/path/to/certs",
        cert_name: "core"

  ## Usage

      # Create a new tenant account
      {:ok, result} = AccountClient.create_tenant_account("acme-corp")
      # result.account_seed should be encrypted and stored in Tenant

      # Generate user credentials (requires decrypted account seed)
      {:ok, creds} = AccountClient.generate_user_credentials(
        "acme-corp",
        account_seed,
        "collector-1",
        :collector
      )

      # Re-sign account JWT (for revocations or limit changes)
      {:ok, result} = AccountClient.sign_account_jwt(
        "acme-corp",
        account_seed,
        revoked_user_keys: ["UABC..."]
      )
  """

  require Logger

  @default_timeout 30_000

  @type credential_type :: :collector | :service | :admin
  @type create_result :: %{
          account_public_key: String.t(),
          account_seed: String.t(),
          account_jwt: String.t()
        }
  @type user_credentials :: %{
          user_public_key: String.t(),
          user_jwt: String.t(),
          creds_file_content: String.t(),
          expires_at: DateTime.t() | nil
        }
  @type sign_result :: %{
          account_public_key: String.t(),
          account_jwt: String.t()
        }

  @doc """
  Create a new NATS account for a tenant.

  Returns the account credentials. The `account_seed` should be encrypted
  (via AshCloak) before storing in the database.

  ## Options

    * `:limits` - AccountLimits struct with resource constraints
    * `:subject_mappings` - Custom subject mappings (defaults are applied automatically)
    * `:timeout` - gRPC call timeout in milliseconds (default: 30000)

  ## Examples

      {:ok, result} = AccountClient.create_tenant_account("acme-corp")
      # Store result.account_seed encrypted in Tenant.nats_account_seed_ciphertext

      {:ok, result} = AccountClient.create_tenant_account("acme-corp",
        limits: %{max_connections: 100, max_subscriptions: 1000}
      )
  """
  @spec create_tenant_account(String.t(), keyword()) ::
          {:ok, create_result()} | {:error, term()}
  def create_tenant_account(tenant_slug, opts \\ []) do
    timeout = opts[:timeout] || @default_timeout

    request = %Proto.CreateTenantAccountRequest{
      tenant_slug: tenant_slug,
      limits: build_limits(opts[:limits]),
      subject_mappings: build_subject_mappings(opts[:subject_mappings])
    }

    with {:ok, channel} <- get_channel() do
      case Proto.NATSAccountService.Stub.create_tenant_account(channel, request, timeout: timeout) do
        {:ok, response} ->
          {:ok,
           %{
             account_public_key: response.account_public_key,
             account_seed: response.account_seed,
             account_jwt: response.account_jwt
           }}

        {:error, %GRPC.RPCError{} = error} ->
          Logger.error(
            "gRPC error creating tenant account for #{tenant_slug}: #{GRPC.RPCError.message(error)}"
          )

          {:error, {:grpc_error, GRPC.RPCError.message(error)}}

        {:error, reason} ->
          Logger.error("Error creating tenant account for #{tenant_slug}: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  @doc """
  Generate NATS user credentials for a tenant's account.

  The `account_seed` must be the decrypted seed from the tenant's stored
  `nats_account_seed_ciphertext` field.

  ## Credential Types

    * `:collector` - For edge collectors (flowgger, trapd, etc.) - can publish events
    * `:service` - For internal services - broader pub/sub within tenant scope
    * `:admin` - For tenant admin access - limited publish, can subscribe

  ## Options

    * `:permissions` - Custom UserPermissions to override defaults
    * `:expiration_seconds` - Credential expiration in seconds (0 = no expiration)
    * `:timeout` - gRPC call timeout in milliseconds

  ## Examples

      {:ok, creds} = AccountClient.generate_user_credentials(
        "acme-corp",
        account_seed,
        "flowgger-collector-1",
        :collector
      )

      {:ok, creds} = AccountClient.generate_user_credentials(
        "acme-corp",
        account_seed,
        "event-writer",
        :service,
        expiration_seconds: 86400  # 24 hours
      )
  """
  @spec generate_user_credentials(String.t(), String.t(), String.t(), credential_type(), keyword()) ::
          {:ok, user_credentials()} | {:error, term()}
  def generate_user_credentials(tenant_slug, account_seed, user_name, credential_type, opts \\ []) do
    timeout = opts[:timeout] || @default_timeout

    request = %Proto.GenerateUserCredentialsRequest{
      tenant_slug: tenant_slug,
      account_seed: account_seed,
      user_name: user_name,
      credential_type: credential_type_to_proto(credential_type),
      permissions: build_permissions(opts[:permissions]),
      expiration_seconds: opts[:expiration_seconds] || 0
    }

    with {:ok, channel} <- get_channel() do
      case Proto.NATSAccountService.Stub.generate_user_credentials(channel, request,
             timeout: timeout
           ) do
        {:ok, response} ->
          expires_at =
            case response.expires_at_unix do
              0 -> nil
              unix ->
                case DateTime.from_unix(unix) do
                  {:ok, dt} -> dt
                  {:error, _} -> nil
                end
            end

          {:ok,
           %{
             user_public_key: response.user_public_key,
             user_jwt: response.user_jwt,
             creds_file_content: response.creds_file_content,
             expires_at: expires_at
           }}

        {:error, %GRPC.RPCError{} = error} ->
          Logger.error(
            "gRPC error generating user credentials for #{tenant_slug}/#{user_name}: #{GRPC.RPCError.message(error)}"
          )

          {:error, {:grpc_error, GRPC.RPCError.message(error)}}

        {:error, reason} ->
          Logger.error(
            "Error generating user credentials for #{tenant_slug}/#{user_name}: #{inspect(reason)}"
          )

          {:error, reason}
      end
    end
  end

  @doc """
  Re-sign an account JWT with updated claims.

  Use this when:
  - Revoking user credentials (add to `revoked_user_keys`)
  - Updating account limits
  - Adding custom subject mappings

  The `account_seed` must be the decrypted seed from the tenant's stored
  `nats_account_seed_ciphertext` field.

  ## Options

    * `:limits` - Updated AccountLimits
    * `:subject_mappings` - Updated subject mappings
    * `:revoked_user_keys` - List of user public keys to revoke
    * `:timeout` - gRPC call timeout in milliseconds

  ## Examples

      # Revoke a user's credentials
      {:ok, result} = AccountClient.sign_account_jwt(
        "acme-corp",
        account_seed,
        revoked_user_keys: ["UABC123..."]
      )
      # Update tenant.nats_account_jwt with result.account_jwt

      # Update limits
      {:ok, result} = AccountClient.sign_account_jwt(
        "acme-corp",
        account_seed,
        limits: %{max_connections: 200}
      )
  """
  @spec sign_account_jwt(String.t(), String.t(), keyword()) ::
          {:ok, sign_result()} | {:error, term()}
  def sign_account_jwt(tenant_slug, account_seed, opts \\ []) do
    timeout = opts[:timeout] || @default_timeout

    request = %Proto.SignAccountJWTRequest{
      tenant_slug: tenant_slug,
      account_seed: account_seed,
      limits: build_limits(opts[:limits]),
      subject_mappings: build_subject_mappings(opts[:subject_mappings]),
      revoked_user_keys: opts[:revoked_user_keys] || []
    }

    with {:ok, channel} <- get_channel() do
      case Proto.NATSAccountService.Stub.sign_account_jwt(channel, request, timeout: timeout) do
        {:ok, response} ->
          {:ok,
           %{
             account_public_key: response.account_public_key,
             account_jwt: response.account_jwt
           }}

        {:error, %GRPC.RPCError{} = error} ->
          Logger.error(
            "gRPC error signing account JWT for #{tenant_slug}: #{GRPC.RPCError.message(error)}"
          )

          {:error, {:grpc_error, GRPC.RPCError.message(error)}}

        {:error, reason} ->
          Logger.error("Error signing account JWT for #{tenant_slug}: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  @type push_jwt_result :: %{
          success: boolean(),
          message: String.t()
        }

  @doc """
  Push an account JWT to the NATS resolver.

  This makes the account immediately available without NATS restart.
  Uses the $SYS.REQ.CLAIMS.UPDATE subject via the system account.

  ## Options

    * `:timeout` - gRPC call timeout in milliseconds (default: 30000)

  ## Examples

      {:ok, result} = AccountClient.push_account_jwt(
        "ABCD123...",  # account public key
        "eyJhbGciOiJFZDI1NTE5..."  # account JWT
      )
      if result.success do
        IO.puts("JWT pushed successfully")
      end
  """
  @spec push_account_jwt(String.t(), String.t(), keyword()) ::
          {:ok, push_jwt_result()} | {:error, term()}
  def push_account_jwt(account_public_key, account_jwt, opts \\ []) do
    timeout = opts[:timeout] || @default_timeout

    request = %Proto.PushAccountJWTRequest{
      account_public_key: account_public_key,
      account_jwt: account_jwt
    }

    with {:ok, channel} <- get_channel() do
      case Proto.NATSAccountService.Stub.push_account_jwt(channel, request, timeout: timeout) do
        {:ok, response} ->
          {:ok,
           %{
             success: response.success,
             message: response.message || ""
           }}

        {:error, %GRPC.RPCError{} = error} ->
          Logger.error("gRPC error pushing account JWT: #{GRPC.RPCError.message(error)}")
          {:error, {:grpc_error, GRPC.RPCError.message(error)}}

        {:error, reason} ->
          Logger.error("Error pushing account JWT: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  @type bootstrap_result :: %{
          operator_public_key: String.t(),
          operator_seed: String.t() | nil,
          operator_jwt: String.t(),
          system_account_public_key: String.t() | nil,
          system_account_seed: String.t() | nil,
          system_account_jwt: String.t() | nil
        }

  @type operator_info :: %{
          operator_public_key: String.t() | nil,
          operator_name: String.t() | nil,
          is_initialized: boolean(),
          system_account_public_key: String.t() | nil
        }

  @doc """
  Bootstrap the NATS operator for the platform.

  This initializes the NATS operator which is the root of trust for all tenant
  account JWTs. Should be called once during initial platform setup.

  ## Options

    * `:operator_name` - Name for the operator (default: "serviceradar")
    * `:existing_seed` - Optional: import existing operator seed instead of generating
    * `:generate_system_account` - Whether to generate the system account (default: true)
    * `:timeout` - gRPC call timeout in milliseconds (default: 30000)

  ## Examples

      # Generate new operator
      {:ok, result} = AccountClient.bootstrap_operator()

      # Import existing operator seed
      {:ok, result} = AccountClient.bootstrap_operator(
        existing_seed: "SO..."
      )
  """
  @spec bootstrap_operator(keyword()) :: {:ok, bootstrap_result()} | {:error, term()}
  def bootstrap_operator(opts \\ []) do
    timeout = opts[:timeout] || @default_timeout

    request = %Proto.BootstrapOperatorRequest{
      operator_name: opts[:operator_name] || "serviceradar",
      existing_operator_seed: opts[:existing_seed] || "",
      generate_system_account: Keyword.get(opts, :generate_system_account, true)
    }

    with {:ok, channel} <- get_channel() do
      case Proto.NATSAccountService.Stub.bootstrap_operator(channel, request, timeout: timeout) do
        {:ok, response} ->
          {:ok,
           %{
             operator_public_key: response.operator_public_key,
             operator_seed: empty_to_nil(response.operator_seed),
             operator_jwt: response.operator_jwt,
             system_account_public_key: empty_to_nil(response.system_account_public_key),
             system_account_seed: empty_to_nil(response.system_account_seed),
             system_account_jwt: empty_to_nil(response.system_account_jwt)
           }}

        {:error, %GRPC.RPCError{} = error} ->
          Logger.error("gRPC error bootstrapping operator: #{GRPC.RPCError.message(error)}")
          {:error, {:grpc_error, GRPC.RPCError.message(error)}}

        {:error, reason} ->
          Logger.error("Error bootstrapping operator: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  @doc """
  Get the current operator status and info.

  Returns information about the NATS operator, including whether it has been
  initialized via bootstrap.

  ## Options

    * `:timeout` - gRPC call timeout in milliseconds (default: 30000)

  ## Examples

      {:ok, info} = AccountClient.get_operator_info()
      if info.is_initialized do
        IO.puts("Operator: \#{info.operator_name}")
      end
  """
  @spec get_operator_info(keyword()) :: {:ok, operator_info()} | {:error, term()}
  def get_operator_info(opts \\ []) do
    timeout = opts[:timeout] || @default_timeout

    request = %Proto.GetOperatorInfoRequest{}

    with {:ok, channel} <- get_channel() do
      case Proto.NATSAccountService.Stub.get_operator_info(channel, request, timeout: timeout) do
        {:ok, response} ->
          {:ok,
           %{
             operator_public_key: empty_to_nil(response.operator_public_key),
             operator_name: empty_to_nil(response.operator_name),
             is_initialized: response.is_initialized,
             system_account_public_key: empty_to_nil(response.system_account_public_key)
           }}

        {:error, %GRPC.RPCError{} = error} ->
          Logger.error("gRPC error getting operator info: #{GRPC.RPCError.message(error)}")
          {:error, {:grpc_error, GRPC.RPCError.message(error)}}

        {:error, reason} ->
          Logger.error("Error getting operator info: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  # Private helpers

  defp empty_to_nil(""), do: nil
  defp empty_to_nil(value), do: value

  defp get_channel do
    # Try to get channel from DataService.Client first
    result =
      try do
        case GenServer.call(ServiceRadar.DataService.Client, :get_channel, 5_000) do
          {:ok, channel} ->
            # Verify the connection is still alive
            conn_pid = channel.adapter_payload.conn_pid

            if Process.alive?(conn_pid) do
              {:ok, channel}
            else
              Logger.warning("DataService.Client connection is dead, creating fresh connection")
              create_fresh_channel()
            end

          {:error, reason} ->
            Logger.warning("DataService.Client not connected: #{inspect(reason)}, creating fresh connection")
            create_fresh_channel()
        end
      catch
        :exit, {:noproc, _} ->
          Logger.warning("DataService.Client not started, creating fresh connection")
          create_fresh_channel()

        :exit, {:timeout, _} ->
          Logger.warning("DataService.Client timeout, creating fresh connection")
          create_fresh_channel()
      end

    result
  end

  defp create_fresh_channel do
    host = System.get_env("DATASVC_HOST", "datasvc")
    port = String.to_integer(System.get_env("DATASVC_PORT", "50057"))
    cert_dir = System.get_env("DATASVC_CERT_DIR", "/etc/serviceradar/certs")
    cert_name = System.get_env("DATASVC_CERT_NAME", "core")
    server_name = System.get_env("DATASVC_SERVER_NAME", "datasvc.serviceradar")

    endpoint = "#{host}:#{port}"

    ssl_opts = [
      cacertfile: String.to_charlist(Path.join(cert_dir, "root.pem")),
      certfile: String.to_charlist(Path.join(cert_dir, "#{cert_name}.pem")),
      keyfile: String.to_charlist(Path.join(cert_dir, "#{cert_name}-key.pem")),
      verify: :verify_peer,
      server_name_indication: String.to_charlist(server_name)
    ]

    connect_opts = [
      cred: GRPC.Credential.new(ssl: ssl_opts),
      adapter_opts: [connect_timeout: 5_000]
    ]

    case GRPC.Stub.connect(endpoint, connect_opts) do
      {:ok, channel} ->
        Logger.debug("Created fresh NATS account gRPC channel to #{endpoint}")
        {:ok, channel}

      {:error, reason} ->
        Logger.error("Failed to create NATS account gRPC channel: #{inspect(reason)}")
        {:error, {:connection_failed, reason}}
    end
  end

  defp build_limits(nil), do: nil

  defp build_limits(limits) when is_map(limits) do
    %Proto.AccountLimits{
      max_connections: limits[:max_connections] || 0,
      max_subscriptions: limits[:max_subscriptions] || 0,
      max_payload_bytes: limits[:max_payload_bytes] || 0,
      max_data_bytes: limits[:max_data_bytes] || 0,
      max_exports: limits[:max_exports] || 0,
      max_imports: limits[:max_imports] || 0,
      allow_wildcard_exports: limits[:allow_wildcard_exports] || false
    }
  end

  defp build_subject_mappings(nil), do: []

  defp build_subject_mappings(mappings) when is_list(mappings) do
    Enum.map(mappings, fn
      %{from: from, to: to} ->
        %Proto.SubjectMapping{from: from, to: to}

      {from, to} ->
        %Proto.SubjectMapping{from: from, to: to}
    end)
  end

  defp build_permissions(nil), do: nil

  defp build_permissions(perms) when is_map(perms) do
    %Proto.UserPermissions{
      publish_allow: perms[:publish_allow] || [],
      publish_deny: perms[:publish_deny] || [],
      subscribe_allow: perms[:subscribe_allow] || [],
      subscribe_deny: perms[:subscribe_deny] || [],
      allow_responses: perms[:allow_responses] || false,
      max_responses: perms[:max_responses] || 0
    }
  end

  defp credential_type_to_proto(:collector), do: :USER_CREDENTIAL_TYPE_COLLECTOR
  defp credential_type_to_proto(:service), do: :USER_CREDENTIAL_TYPE_SERVICE
  defp credential_type_to_proto(:admin), do: :USER_CREDENTIAL_TYPE_ADMIN
  defp credential_type_to_proto(_), do: :USER_CREDENTIAL_TYPE_COLLECTOR
end
