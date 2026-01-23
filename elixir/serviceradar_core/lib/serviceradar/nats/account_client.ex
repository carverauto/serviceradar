defmodule ServiceRadar.NATS.AccountClient do
  @moduledoc """
  gRPC client for the datasvc NATSAccountService.

  This client is used to create and manage NATS accounts for account isolation.
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

      # Create a new account
      {:ok, result} = AccountClient.create_account("edge-account")
      # result.account_seed should be encrypted and stored securely

      # Generate user credentials (requires decrypted account seed)
      {:ok, creds} = AccountClient.generate_user_credentials(
        "edge-account",
        account_seed,
        "collector-1",
        :collector
      )

      # Re-sign account JWT (for revocations or limit changes)
      {:ok, result} = AccountClient.sign_account_jwt(
        "edge-account",
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
  Create a new NATS account.

  Returns the account credentials. The `account_seed` should be encrypted
  (via AshCloak) before storing in the database.

  ## Options

    * `:limits` - AccountLimits struct with resource constraints
    * `:subject_mappings` - Custom subject mappings (defaults are applied automatically)
    * `:exports` - Stream exports for cross-account consumption (optional)
    * `:timeout` - gRPC call timeout in milliseconds (default: 30000)

  ## Examples

      {:ok, result} = AccountClient.create_account("edge-account")
      # Store result.account_seed encrypted in secure storage

      {:ok, result} = AccountClient.create_account("edge-account",
        limits: %{max_connections: 100, max_subscriptions: 1000}
      )
  """
  @spec create_account(String.t(), keyword()) ::
          {:ok, create_result()} | {:error, term()}
  def create_account(account_name, opts \\ []) do
    timeout = opts[:timeout] || @default_timeout

    request = %Proto.CreateAccountRequest{
      account_name: account_name,
      limits: build_limits(opts[:limits]),
      subject_mappings: build_subject_mappings(opts[:subject_mappings]),
      exports: build_stream_exports(opts[:exports])
    }

    with {:ok, channel} <- get_channel() do
      case Proto.NATSAccountService.Stub.create_account(channel, request, timeout: timeout) do
        {:ok, response} ->
          {:ok,
           %{
             account_public_key: response.account_public_key,
             account_seed: response.account_seed,
             account_jwt: response.account_jwt
           }}

        {:error, %GRPC.RPCError{} = error} ->
          Logger.error(
            "gRPC error creating account #{account_name}: #{GRPC.RPCError.message(error)}"
          )

          {:error, {:grpc_error, GRPC.RPCError.message(error)}}

        {:error, reason} ->
          Logger.error("Error creating account #{account_name}: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  @doc """
  Generate NATS user credentials for an account.

  The `account_seed` must be the decrypted seed from stored configuration.

  ## Credential Types

    * `:collector` - For edge collectors (flowgger, trapd, etc.) - can publish events
    * `:service` - For internal services - broader pub/sub within account scope
    * `:admin` - For admin access - limited publish, can subscribe

  ## Options

    * `:permissions` - Custom UserPermissions to override defaults
    * `:expiration_seconds` - Credential expiration in seconds (0 = no expiration)
    * `:timeout` - gRPC call timeout in milliseconds

  ## Examples

      {:ok, creds} = AccountClient.generate_user_credentials(
        "edge-account",
        account_seed,
        "flowgger-collector-1",
        :collector
      )

      {:ok, creds} = AccountClient.generate_user_credentials(
        "edge-account",
        account_seed,
        "event-writer",
        :service,
        expiration_seconds: 86_400  # 24 hours
      )
  """
  @spec generate_user_credentials(
          String.t(),
          String.t(),
          String.t(),
          credential_type(),
          keyword()
        ) ::
          {:ok, user_credentials()} | {:error, term()}
  def generate_user_credentials(
        account_name,
        account_seed,
        user_name,
        credential_type,
        opts \\ []
      ) do
    timeout = opts[:timeout] || @default_timeout

    request = %Proto.GenerateUserCredentialsRequest{
      account_name: account_name,
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
          build_user_credentials(response)

        {:error, %GRPC.RPCError{} = error} ->
          Logger.error(
            "gRPC error generating user credentials for #{account_name}/#{user_name}: #{GRPC.RPCError.message(error)}"
          )

          {:error, {:grpc_error, GRPC.RPCError.message(error)}}

        {:error, reason} ->
          Logger.error(
            "Error generating user credentials for #{account_name}/#{user_name}: #{inspect(reason)}"
          )

          {:error, reason}
      end
    end
  end

  defp build_user_credentials(response) do
    {:ok,
     %{
       user_public_key: response.user_public_key,
       user_jwt: response.user_jwt,
       creds_file_content: response.creds_file_content,
       expires_at: decode_expires_at(response.expires_at_unix)
     }}
  end

  defp decode_expires_at(0), do: nil

  defp decode_expires_at(unix) do
    case DateTime.from_unix(unix) do
      {:ok, dt} -> dt
      {:error, _} -> nil
    end
  end

  @doc """
  Re-sign an account JWT with updated claims.

  Use this when:
  - Revoking user credentials (add to `revoked_user_keys`)
  - Updating account limits
  - Adding custom subject mappings

  The `account_seed` must be the decrypted seed from stored configuration.

  ## Options

    * `:limits` - Updated AccountLimits
    * `:subject_mappings` - Updated subject mappings
    * `:revoked_user_keys` - List of user public keys to revoke
    * `:exports` - Stream exports for cross-account consumption
    * `:imports` - Stream imports from external accounts
    * `:timeout` - gRPC call timeout in milliseconds

  ## Examples

      # Revoke a user's credentials
      {:ok, result} = AccountClient.sign_account_jwt(
        "edge-account",
        account_seed,
        revoked_user_keys: ["UABC123..."]
      )
      # Update stored account_jwt with result.account_jwt

      # Update limits
      {:ok, result} = AccountClient.sign_account_jwt(
        "edge-account",
        account_seed,
        limits: %{max_connections: 200}
      )
  """
  @spec sign_account_jwt(String.t(), String.t(), keyword()) ::
          {:ok, sign_result()} | {:error, term()}
  def sign_account_jwt(account_name, account_seed, opts \\ []) do
    timeout = opts[:timeout] || @default_timeout

    request = %Proto.SignAccountJWTRequest{
      account_name: account_name,
      account_seed: account_seed,
      limits: build_limits(opts[:limits]),
      subject_mappings: build_subject_mappings(opts[:subject_mappings]),
      revoked_user_keys: opts[:revoked_user_keys] || [],
      exports: build_stream_exports(opts[:exports]),
      imports: build_stream_imports(opts[:imports])
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
            "gRPC error signing account JWT for #{account_name}: #{GRPC.RPCError.message(error)}"
          )

          {:error, {:grpc_error, GRPC.RPCError.message(error)}}

        {:error, reason} ->
          Logger.error("Error signing account JWT for #{account_name}: #{inspect(reason)}")
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

  This initializes the NATS operator which is the root of trust for all account
  JWTs. Should be called once during initial platform setup.

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
            Logger.warning(
              "DataService.Client not connected: #{inspect(reason)}, creating fresh connection"
            )

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

    endpoint = "#{host}:#{port}"

    with {:ok, cred_opts} <- build_cred_opts() do
      connect_opts =
        cred_opts
        |> Keyword.put(:adapter_opts, connect_timeout: 5_000)

      case GRPC.Stub.connect(endpoint, connect_opts) do
        {:ok, channel} ->
          Logger.debug("Created fresh NATS account gRPC channel to #{endpoint}")
          {:ok, channel}

        {:error, reason} ->
          Logger.error("Failed to create NATS account gRPC channel: #{inspect(reason)}")
          {:error, {:connection_failed, reason}}
      end
    else
      {:error, reason} ->
        Logger.error("Failed to build NATS account gRPC credentials: #{inspect(reason)}")
        {:error, {:connection_failed, reason}}
    end
  end

  defp build_cred_opts do
    sec_mode = System.get_env("DATASVC_SEC_MODE")
    ssl = System.get_env("DATASVC_SSL", "false") in ["true", "1", "yes"]

    case normalize_sec_mode(sec_mode, ssl) do
      :spiffe ->
        spiffe_cert_dir =
          System.get_env("DATASVC_SPIFFE_CERT_DIR") ||
            System.get_env("DATASVC_CERT_DIR", "/etc/serviceradar/certs")

        case ServiceRadar.SPIFFE.client_ssl_opts(cert_dir: spiffe_cert_dir) do
          {:ok, ssl_opts} ->
            Logger.info("Connecting to datasvc with SPIFFE mTLS (account service)")
            {:ok, [cred: GRPC.Credential.new(ssl: ssl_opts)]}

          {:error, reason} ->
            Logger.error("SPIFFE mTLS not available for datasvc: #{inspect(reason)}")
            {:error, {:spiffe_unavailable, reason}}
        end

      :mtls ->
        cert_dir = System.get_env("DATASVC_CERT_DIR", "/etc/serviceradar/certs")
        cert_name = System.get_env("DATASVC_CERT_NAME", "core")
        server_name = System.get_env("DATASVC_SERVER_NAME", "datasvc.serviceradar")

        ssl_opts = [
          cacertfile: String.to_charlist(Path.join(cert_dir, "root.pem")),
          certfile: String.to_charlist(Path.join(cert_dir, "#{cert_name}.pem")),
          keyfile: String.to_charlist(Path.join(cert_dir, "#{cert_name}-key.pem")),
          verify: :verify_peer,
          server_name_indication: String.to_charlist(server_name)
        ]

        {:ok, [cred: GRPC.Credential.new(ssl: ssl_opts)]}

      :tls ->
        {:ok, [cred: GRPC.Credential.new(ssl: [])]}

      :plaintext ->
        {:ok, []}
    end
  end

  defp normalize_sec_mode(nil, ssl) do
    if ssl do
      cert_dir = System.get_env("DATASVC_CERT_DIR")
      if is_binary(cert_dir), do: :mtls, else: :tls
    else
      :plaintext
    end
  end

  defp normalize_sec_mode("", ssl), do: normalize_sec_mode(nil, ssl)

  defp normalize_sec_mode(value, ssl) do
    case String.downcase(String.trim(value)) do
      "spiffe" -> :spiffe
      "mtls" -> :mtls
      "tls" -> :tls
      "plaintext" -> :plaintext
      "none" -> :plaintext
      _ -> if ssl, do: :mtls, else: :plaintext
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

  defp build_stream_exports(nil), do: []

  defp build_stream_exports(exports) when is_list(exports) do
    Enum.map(exports, fn
      %{subject: subject, name: name} ->
        %Proto.StreamExport{subject: subject, name: name}

      %{subject: subject} ->
        %Proto.StreamExport{subject: subject}

      {subject, name} ->
        %Proto.StreamExport{subject: subject, name: name}
    end)
  end

  defp build_stream_imports(nil), do: []

  defp build_stream_imports(imports) when is_list(imports) do
    Enum.map(imports, fn
      %{
        subject: subject,
        account_public_key: account_public_key,
        local_subject: local_subject,
        name: name
      } ->
        %Proto.StreamImport{
          subject: subject,
          account_public_key: account_public_key,
          local_subject: local_subject,
          name: name
        }

      %{subject: subject, account_public_key: account_public_key, local_subject: local_subject} ->
        %Proto.StreamImport{
          subject: subject,
          account_public_key: account_public_key,
          local_subject: local_subject
        }

      %{subject: subject, account_public_key: account_public_key} ->
        %Proto.StreamImport{
          subject: subject,
          account_public_key: account_public_key
        }

      {subject, account_public_key} ->
        %Proto.StreamImport{
          subject: subject,
          account_public_key: account_public_key
        }
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
