defmodule ServiceRadar.Edge.OnboardingPackages do
  @moduledoc """
  Ash-based context module for edge onboarding package operations.

  Provides CRUD operations for managing edge onboarding packages using
  the Ash OnboardingPackage resource, including token generation, delivery,
  revocation, and soft-delete.

  This module serves as a facade over the Ash resource, providing a familiar
  API while leveraging Ash's authorization and state machine features.
  """

  import Ash.Expr
  require Ash.Query

  alias ServiceRadar.Edge.OnboardingPackage
  alias ServiceRadar.Edge.OnboardingEvents
  alias ServiceRadar.Edge.Crypto
  alias ServiceRadar.Edge.TenantCA
  alias ServiceRadar.Edge.TenantCA.Generator, as: CertGenerator
  alias ServiceRadar.Cluster.TenantSchemas

  @default_limit 100
  @default_join_token_ttl_seconds 86_400
  @default_download_token_ttl_seconds 86_400

  @type filter :: %{
          optional(:status) => [atom()],
          optional(:component_type) => [atom()],
          optional(:gateway_id) => String.t(),
          optional(:component_id) => String.t(),
          optional(:parent_id) => String.t(),
          optional(:limit) => pos_integer()
        }

  @doc """
  Lists edge onboarding packages with optional filters.

  ## Options

    * `:status` - List of status atoms to filter by (e.g., [:issued, :delivered])
    * `:component_type` - List of component types to filter by (e.g., [:gateway, :checker, :sync])
    * `:gateway_id` - Filter by gateway_id
    * `:component_id` - Filter by component_id
    * `:parent_id` - Filter by parent_id
    * `:limit` - Maximum number of results (default: 100)
    * `:actor` - The actor performing the query (required for authorization)

  ## Examples

      iex> list(%{status: [:issued], limit: 10}, actor: user)
      {:ok, [%OnboardingPackage{}, ...]}

  """
  @spec list(filter(), keyword()) :: {:ok, [OnboardingPackage.t()]} | {:error, Ash.Error.t()}
  def list(filters \\ %{}, opts \\ []) do
    limit = Map.get(filters, :limit, @default_limit)
    actor = Keyword.get(opts, :actor)
    tenant = resolve_tenant(opts)

    OnboardingPackage
    |> Ash.Query.for_read(:read, %{}, actor: actor, tenant: tenant)
    |> apply_filters(filters)
    |> Ash.Query.filter(expr(is_nil(deleted_at)))
    |> Ash.Query.sort(created_at: :desc)
    |> Ash.Query.limit(limit)
    |> Ash.read()
  end

  @doc """
  Lists packages, returning empty list on error.
  """
  @spec list!(filter(), keyword()) :: [OnboardingPackage.t()]
  def list!(filters \\ %{}, opts \\ []) do
    case list(filters, opts) do
      {:ok, packages} -> packages
      {:error, _} -> []
    end
  end

  @doc """
  Gets a single package by ID.

  Returns `{:ok, package}` or `{:error, :not_found}`.
  """
  @spec get(String.t(), keyword()) :: {:ok, OnboardingPackage.t()} | {:error, :not_found}
  def get(id, opts \\ []) when is_binary(id) do
    actor = Keyword.get(opts, :actor)
    authorize? = Keyword.get(opts, :authorize?, true)
    tenant = resolve_tenant(opts)

    case Ash.get(OnboardingPackage, id, actor: actor, authorize?: authorize?, tenant: tenant) do
      {:ok, package} -> {:ok, package}
      {:error, %Ash.Error.Query.NotFound{}} -> {:error, :not_found}
      {:error, _} -> {:error, :not_found}
    end
  end

  @doc """
  Gets a single package by ID, raising if not found.
  """
  @spec get!(String.t(), keyword()) :: OnboardingPackage.t()
  def get!(id, opts \\ []) do
    case get(id, opts) do
      {:ok, package} -> package
      {:error, :not_found} -> raise "Package not found: #{id}"
    end
  end

  @doc """
  Creates a new edge onboarding package with tokens.

  ## Options

    * `:join_token_ttl_seconds` - TTL for join token (default: 86400)
    * `:download_token_ttl_seconds` - TTL for download token (default: 86400)
    * `:actor` - User/system creating the package (required for authorization)
    * `:source_ip` - IP address of the creator

  ## Returns

      {:ok, %{package: package, join_token: token, download_token: token}}

  """
  @spec create(map(), keyword()) ::
          {:ok,
           %{package: OnboardingPackage.t(), join_token: String.t(), download_token: String.t()}}
          | {:error, Ash.Error.t()}
  def create(attrs, opts \\ []) do
    join_ttl = Keyword.get(opts, :join_token_ttl_seconds, @default_join_token_ttl_seconds)

    download_ttl =
      Keyword.get(opts, :download_token_ttl_seconds, @default_download_token_ttl_seconds)

    actor = Keyword.get(opts, :actor)
    source_ip = Keyword.get(opts, :source_ip)
    authorize? = Keyword.get(opts, :authorize?, true)
    tenant = resolve_tenant(opts, attrs)

    # Generate tokens
    join_token = Crypto.generate_token()
    download_token = Crypto.generate_token()

    now = DateTime.utc_now() |> DateTime.truncate(:second)
    join_expires = DateTime.add(now, join_ttl, :second)
    download_expires = DateTime.add(now, download_ttl, :second)

    # Encrypt join token and hash download token
    join_token_ciphertext = Crypto.encrypt(join_token)
    download_token_hash = Crypto.hash_token(download_token)

    # Prepare attributes for Ash create
    create_attrs =
      attrs
      |> Map.put(:created_by, get_actor_name(actor))

    changeset =
      OnboardingPackage
      |> Ash.Changeset.for_create(:create, create_attrs,
        actor: actor,
        authorize?: authorize?,
        tenant: tenant
      )
      |> Ash.Changeset.force_change_attribute(:join_token_ciphertext, join_token_ciphertext)
      |> Ash.Changeset.force_change_attribute(:join_token_expires_at, join_expires)
      |> Ash.Changeset.force_change_attribute(:download_token_hash, download_token_hash)
      |> Ash.Changeset.force_change_attribute(:download_token_expires_at, download_expires)

    case Ash.create(changeset) do
      {:ok, package} ->
        # Record creation event
        OnboardingEvents.record(package.id, :created,
          actor: get_actor_name(actor),
          source_ip: source_ip,
          tenant_id: package.tenant_id
        )

        {:ok,
         %{
           package: package,
           join_token: join_token,
           download_token: download_token
         }}

      {:error, error} ->
        {:error, error}
    end
  end

  @doc """
  Delivers a package to a client, verifying the download token.

  Returns the decrypted join token and bundle if the download token is valid.

  ## Errors

    * `:not_found` - Package does not exist
    * `:invalid_token` - Download token does not match
    * `:expired` - Download token has expired
    * `:already_delivered` - Package was already delivered
    * `:revoked` - Package was revoked

  """
  @spec deliver(String.t(), String.t(), keyword()) ::
          {:ok,
           %{package: OnboardingPackage.t(), join_token: String.t(), bundle_pem: String.t() | nil}}
          | {:error, atom()}
  def deliver(package_id, download_token, opts \\ []) do
    actor = Keyword.get(opts, :actor)
    source_ip = Keyword.get(opts, :source_ip)
    authorize? = Keyword.get(opts, :authorize?, true)
    tenant = resolve_tenant(opts)

    with {:ok, package} <- get(package_id, actor: actor, authorize?: authorize?, tenant: tenant),
         :ok <- verify_deliverable(package),
         :ok <- verify_download_token(package, download_token) do
      # Decrypt join token
      join_token = Crypto.decrypt(package.join_token_ciphertext)

      # Decrypt bundle if present
      bundle_pem =
        if package.bundle_ciphertext do
          Crypto.decrypt(package.bundle_ciphertext)
        end

      # Update package status to delivered using Ash state machine
      case package
           |> Ash.Changeset.for_update(:deliver, %{},
             actor: actor,
             authorize?: authorize?,
             tenant: tenant
           )
           |> Ash.update() do
        {:ok, updated_package} ->
          # Record delivery event
          OnboardingEvents.record(package_id, :delivered,
            actor: get_actor_name(actor),
            source_ip: source_ip,
            tenant_id: updated_package.tenant_id
          )

          {:ok,
           %{
             package: updated_package,
             join_token: join_token,
             bundle_pem: bundle_pem
           }}

        {:error, error} ->
          {:error, error}
      end
    end
  end

  @doc """
  Revokes a package, preventing further delivery or activation.
  """
  @spec revoke(String.t(), keyword()) :: {:ok, OnboardingPackage.t()} | {:error, atom()}
  def revoke(package_id, opts \\ []) do
    actor = Keyword.get(opts, :actor)
    source_ip = Keyword.get(opts, :source_ip)
    reason = Keyword.get(opts, :reason)
    authorize? = Keyword.get(opts, :authorize?, true)
    tenant = resolve_tenant(opts)

    with {:ok, package} <- get(package_id, actor: actor, authorize?: authorize?, tenant: tenant),
         :ok <- verify_not_revoked(package) do
      case package
           |> Ash.Changeset.for_update(:revoke, %{reason: reason},
             actor: actor,
             authorize?: authorize?,
             tenant: tenant
           )
           |> Ash.update() do
        {:ok, updated_package} ->
          # Record revocation event
          OnboardingEvents.record(package_id, :revoked,
            actor: get_actor_name(actor),
            source_ip: source_ip,
            details: %{reason: reason},
            tenant_id: updated_package.tenant_id
          )

          {:ok, updated_package}

        {:error, error} ->
          {:error, error}
      end
    end
  end

  @doc """
  Soft-deletes a package.
  """
  @spec delete(String.t(), keyword()) :: {:ok, OnboardingPackage.t()} | {:error, atom()}
  def delete(package_id, opts \\ []) do
    actor = Keyword.get(opts, :actor)
    source_ip = Keyword.get(opts, :source_ip)
    reason = Keyword.get(opts, :reason)
    authorize? = Keyword.get(opts, :authorize?, true)
    tenant = resolve_tenant(opts)

    with {:ok, package} <- get(package_id, actor: actor, authorize?: authorize?, tenant: tenant) do
      case package
           |> Ash.Changeset.for_update(
             :soft_delete,
             %{deleted_by: get_actor_name(actor), deleted_reason: reason},
             actor: actor,
             authorize?: authorize?,
             tenant: tenant
           )
           |> Ash.update() do
        {:ok, updated_package} ->
          # Record deletion event
          OnboardingEvents.record(package_id, :deleted,
            actor: get_actor_name(actor),
            source_ip: source_ip,
            details: %{reason: reason},
            tenant_id: updated_package.tenant_id
          )

          {:ok, updated_package}

        {:error, error} ->
          {:error, error}
      end
    end
  end

  @doc """
  Returns default selectors and metadata for package creation.
  """
  @spec defaults() :: %{selectors: [String.t()], metadata: map(), security_mode: String.t()}
  def defaults do
    %{
      selectors: default_selectors(),
      metadata: default_metadata(),
      security_mode: configured_security_mode()
    }
  end

  @doc """
  Returns the configured security mode from the environment.
  Defaults to "mtls" for docker deployments.
  """
  @spec configured_security_mode() :: String.t()
  def configured_security_mode do
    Application.get_env(:serviceradar_web_ng, :security_mode, "mtls")
  end

  # Private functions

  defp apply_filters(query, filters) do
    query
    |> maybe_filter_status(Map.get(filters, :status))
    |> maybe_filter_component_type(Map.get(filters, :component_type))
    |> maybe_filter_gateway_id(Map.get(filters, :gateway_id))
    |> maybe_filter_component_id(Map.get(filters, :component_id))
    |> maybe_filter_parent_id(Map.get(filters, :parent_id))
  end

  defp maybe_filter_status(query, nil), do: query
  defp maybe_filter_status(query, []), do: query

  defp maybe_filter_status(query, statuses) when is_list(statuses) do
    Ash.Query.filter(query, expr(status in ^statuses))
  end

  defp maybe_filter_component_type(query, nil), do: query
  defp maybe_filter_component_type(query, []), do: query

  defp maybe_filter_component_type(query, types) when is_list(types) do
    Ash.Query.filter(query, expr(component_type in ^types))
  end

  defp maybe_filter_gateway_id(query, nil), do: query
  defp maybe_filter_gateway_id(query, ""), do: query

  defp maybe_filter_gateway_id(query, value) do
    Ash.Query.filter(query, expr(gateway_id == ^value))
  end

  defp maybe_filter_component_id(query, nil), do: query
  defp maybe_filter_component_id(query, ""), do: query

  defp maybe_filter_component_id(query, value) do
    Ash.Query.filter(query, expr(component_id == ^value))
  end

  defp maybe_filter_parent_id(query, nil), do: query
  defp maybe_filter_parent_id(query, ""), do: query

  defp maybe_filter_parent_id(query, value) do
    Ash.Query.filter(query, expr(parent_id == ^value))
  end

  defp verify_deliverable(package) do
    cond do
      package.status == :revoked -> {:error, :revoked}
      package.status == :deleted -> {:error, :deleted}
      package.status == :delivered -> {:error, :already_delivered}
      package.status == :activated -> {:error, :already_activated}
      true -> :ok
    end
  end

  defp verify_download_token(package, token) do
    now = DateTime.utc_now()

    cond do
      is_nil(package.download_token_expires_at) ->
        {:error, :no_token}

      DateTime.compare(now, package.download_token_expires_at) == :gt ->
        {:error, :expired}

      not Crypto.verify_token(token, package.download_token_hash) ->
        {:error, :invalid_token}

      true ->
        :ok
    end
  end

  defp verify_not_revoked(package) do
    if package.status == :revoked do
      {:error, :already_revoked}
    else
      :ok
    end
  end

  defp get_actor_name(nil), do: "system"
  defp get_actor_name(actor) when is_binary(actor), do: actor
  defp get_actor_name(%{email: email}), do: email
  defp get_actor_name(_), do: "system"

  defp default_selectors do
    Application.get_env(:serviceradar_web_ng, :edge_onboarding, [])
    |> Keyword.get(:default_selectors, [])
  end

  defp default_metadata do
    Application.get_env(:serviceradar_web_ng, :edge_onboarding, [])
    |> Keyword.get(:default_metadata, %{})
  end

  defp resolve_tenant(opts, attrs \\ %{}) do
    tenant_value =
      Keyword.get(opts, :tenant) ||
        Keyword.get(opts, :tenant_id) ||
        Map.get(attrs, :tenant_id) ||
        Map.get(attrs, "tenant_id")

    TenantSchemas.schema_for_tenant(tenant_value)
  end

  @doc """
  Generates a component certificate signed by the tenant's CA.

  This creates a certificate with the CN format:
  `<component_id>.<partition_id>.<tenant_slug>.serviceradar`

  And includes a SPIFFE URI SAN:
  `spiffe://serviceradar.local/<component_type>/<tenant_slug>/<partition_id>/<component_id>`

  ## Parameters

    * `tenant_id` - The tenant UUID
    * `component_id` - Unique component identifier
    * `component_type` - :gateway, :agent, :checker, or :sync
    * `partition_id` - Network partition identifier (default: "default")
    * `opts` - Additional options:
      * `:validity_days` - Certificate validity (default: 365)
      * `:dns_names` - Additional DNS SANs

  ## Returns

    * `{:ok, %{certificate_pem: pem, private_key_pem: pem, ca_chain_pem: pem, spiffe_id: string}}`
    * `{:error, reason}`

  """
  @spec generate_component_certificate(String.t(), String.t(), atom(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def generate_component_certificate(tenant_id, component_id, component_type, partition_id \\ "default", opts \\ []) do
    with {:ok, tenant_ca} <- get_tenant_ca(tenant_id),
         {:ok, decrypted_ca} <- decrypt_ca_private_key(tenant_ca) do
      CertGenerator.generate_component_cert(
        decrypted_ca,
        component_id,
        component_type,
        partition_id,
        opts
      )
    end
  end

  @doc """
  Creates a package with a component certificate signed by the tenant's CA.

  This is the preferred way to create packages for multi-tenant deployments.
  It automatically:
  1. Gets or generates the tenant's CA
  2. Generates a component certificate signed by the tenant CA
  3. Includes the certificate bundle in the package

  ## Options

  Same as `create/2`, plus:
    * `:partition_id` - Network partition (default: "default")
    * `:cert_validity_days` - Component cert validity (default: 365)

  """
  @spec create_with_tenant_cert(map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def create_with_tenant_cert(attrs, opts \\ []) do
    tenant_id = Keyword.fetch!(opts, :tenant)
    tenant_schema = TenantSchemas.schema_for_tenant(tenant_id)
    partition_id = Keyword.get(opts, :partition_id, attrs[:site] || "default")
    cert_validity = Keyword.get(opts, :cert_validity_days, 365)

    component_id = attrs[:component_id] || generate_component_id(attrs[:component_type])
    component_type = attrs[:component_type] || :gateway

    # Generate component certificate
    with {:ok, cert_data} <- generate_component_certificate(
           tenant_id,
           component_id,
           component_type,
           partition_id,
           validity_days: cert_validity
         ) do

      # Build the bundle (cert + key + CA chain in a single PEM)
      bundle_pem = build_certificate_bundle(cert_data)
      bundle_ciphertext = Crypto.encrypt(bundle_pem)

      # Add the SPIFFE ID to the package
      attrs_with_cert = attrs
        |> Map.put(:component_id, component_id)
        |> Map.put(:downstream_spiffe_id, cert_data.spiffe_id)

      # Create the package with the encrypted bundle
      case create(attrs_with_cert, opts) do
        {:ok, result} ->
          # Update with the certificate bundle
          updated = result.package
            |> Ash.Changeset.for_update(:update_tokens, %{
              bundle_ciphertext: bundle_ciphertext,
              downstream_spiffe_id: cert_data.spiffe_id
            }, authorize?: false, tenant: tenant_schema)
            |> Ash.update!()

          {:ok, Map.put(result, :package, updated)
                |> Map.put(:certificate_data, cert_data)}

        error -> error
      end
    end
  end

  # Gets the active tenant CA, generating one if it doesn't exist
  defp get_tenant_ca(tenant_id) do
    tenant_schema = TenantSchemas.schema_for_tenant(tenant_id)

    case TenantCA
         |> Ash.Query.set_tenant(tenant_schema)
         |> Ash.Query.filter(tenant_id == ^tenant_id and status == :active)
         |> Ash.read_one(authorize?: false) do
      {:ok, nil} ->
        # No active CA, need to generate one
        case Ash.get(ServiceRadar.Identity.Tenant, tenant_id, authorize?: false) do
          {:ok, tenant} ->
            # Use the action on Tenant to generate a CA
            ServiceRadar.Identity.Tenant
            |> Ash.ActionInput.for_action(:generate_ca, %{tenant: tenant})
            |> Ash.run_action(authorize?: false)

          error -> error
        end

      {:ok, ca} -> {:ok, ca}
      error -> error
    end
  end

  # Decrypts the CA private key for signing (AshCloak handles decryption)
  defp decrypt_ca_private_key(tenant_ca) do
    # Load with decryption - AshCloak will decrypt the private key
    tenant_schema = TenantSchemas.schema_for_tenant(tenant_ca.tenant_id)

    case Ash.get(TenantCA, tenant_ca.id,
           tenant: tenant_schema,
           authorize?: false,
           load: [:tenant]
         ) do
      {:ok, ca} -> {:ok, ca}
      error -> error
    end
  end

  defp build_certificate_bundle(cert_data) do
    """
    # Component Certificate
    #{cert_data.certificate_pem}
    # Component Private Key
    #{cert_data.private_key_pem}
    # CA Chain
    #{cert_data.ca_chain_pem}
    """
  end

  defp generate_component_id(component_type) do
    short_id = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
    "#{component_type}-#{short_id}"
  end
end
