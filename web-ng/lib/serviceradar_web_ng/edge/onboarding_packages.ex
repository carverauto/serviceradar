defmodule ServiceRadarWebNG.Edge.OnboardingPackages do
  @moduledoc """
  Context module for edge onboarding package operations.

  Delegates to ServiceRadar.Edge.OnboardingPackages Ash-based implementation
  while maintaining backwards compatibility with existing callers.
  """

  alias ServiceRadar.Edge.OnboardingPackages, as: AshPackages
  alias ServiceRadar.Edge.OnboardingPackage
  alias ServiceRadar.Identity.Tenant

  @type filter :: %{
          optional(:status) => [String.t()],
          optional(:component_type) => [String.t()],
          optional(:gateway_id) => String.t(),
          optional(:component_id) => String.t(),
          optional(:parent_id) => String.t(),
          optional(:limit) => pos_integer()
        }

  @doc """
  Lists edge onboarding packages with optional filters.

  ## Options

    * `:status` - List of status values to filter by (e.g., ["issued", "delivered"])
    * `:component_type` - List of component types to filter by (e.g., ["gateway", "checker"])
    * `:gateway_id` - Filter by gateway_id
    * `:component_id` - Filter by component_id
    * `:parent_id` - Filter by parent_id
    * `:limit` - Maximum number of results (default: 100)

  ## Examples

      iex> list(%{status: ["issued"], limit: 10})
      [%OnboardingPackage{}, ...]

  """
  @spec list(filter(), keyword()) :: [OnboardingPackage.t()]
  def list(filters \\ %{}, opts \\ []) do
    # Convert string statuses to atoms if present
    filters = normalize_filters(filters)
    tenant = require_tenant!(opts)
    opts = [actor: system_actor(), authorize?: false, tenant: tenant]

    AshPackages.list!(filters, opts)
  end

  @doc """
  Gets a single package by ID.

  Returns `{:ok, package}` or `{:error, :not_found}`.
  """
  @spec get(String.t(), keyword()) :: {:ok, OnboardingPackage.t()} | {:error, :not_found}
  def get(id, opts \\ [])

  def get(id, opts) when is_binary(id) do
    tenant = require_tenant!(opts)
    opts = [actor: system_actor(), authorize?: false, tenant: tenant]
    AshPackages.get(id, opts)
  end

  def get(_, _opts), do: {:error, :not_found}

  @doc """
  Gets a single package by ID, raising if not found.
  """
  @spec get!(String.t(), keyword()) :: OnboardingPackage.t()
  def get!(id, opts \\ []) do
    tenant = require_tenant!(opts)
    opts = [actor: system_actor(), authorize?: false, tenant: tenant]
    AshPackages.get!(id, opts)
  end

  @doc """
  Creates a new edge onboarding package with tokens.

  ## Options

    * `:join_token_ttl_seconds` - TTL for join token (default: 86400)
    * `:download_token_ttl_seconds` - TTL for download token (default: 86400)
    * `:actor` - User/system creating the package
    * `:source_ip` - IP address of the creator

  ## Returns

      {:ok, %{package: package, join_token: token, download_token: token}}

  """
  @spec create(map(), keyword()) ::
          {:ok,
           %{package: OnboardingPackage.t(), join_token: String.t(), download_token: String.t()}}
          | {:error, Ash.Error.t()}
  def create(attrs, opts \\ []) do
    actor = Keyword.get(opts, :actor)
    tenant = require_tenant!(opts)

    opts_with_actor =
      opts
      |> Keyword.put(:actor, actor || system_actor())
      |> Keyword.put(:authorize?, false)
      |> Keyword.put(:tenant, tenant)

    AshPackages.create(attrs, opts_with_actor)
  end

  @doc """
  Creates an edge onboarding package with automatic tenant certificate generation.

  This is the preferred method for production deployments. It automatically:
  1. Gets or generates the tenant's intermediate CA (on first use)
  2. Generates a component certificate signed by the tenant CA
  3. Includes the encrypted certificate bundle in the package

  The certificate CN follows the format: `<component_id>.<partition_id>.<tenant_slug>.serviceradar`

  ## Options

    * `:tenant` - Tenant ID (required)
    * `:partition_id` - Network partition identifier (default: "default")
    * `:cert_validity_days` - Component certificate validity (default: 365)
    * `:join_token_ttl_seconds` - TTL for join token (default: 86400)
    * `:download_token_ttl_seconds` - TTL for download token (default: 86400)
    * `:actor` - User/system creating the package
    * `:source_ip` - IP address of the creator

  ## Returns

      {:ok, %{
        package: package,
        join_token: token,
        download_token: token,
        certificate_data: %{
          certificate_pem: pem,
          private_key_pem: pem,
          ca_chain_pem: pem,
          spiffe_id: string
        }
      }}

  ## Examples

      iex> create_with_tenant_cert(
      ...>   %{label: "prod-gateway-01", component_type: :gateway},
      ...>   tenant: "tenant-uuid",
      ...>   actor: current_user
      ...> )
      {:ok, %{package: %OnboardingPackage{}, certificate_data: %{...}}}

  """
  @spec create_with_tenant_cert(map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def create_with_tenant_cert(attrs, opts \\ []) do
    actor = Keyword.get(opts, :actor)
    tenant = require_tenant!(opts)

    opts_with_actor =
      opts
      |> Keyword.put(:actor, actor || system_actor())
      |> Keyword.put(:authorize?, false)
      |> Keyword.put(:tenant, tenant)

    AshPackages.create_with_tenant_cert(attrs, opts_with_actor)
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
    tenant = require_tenant!(opts)

    opts_with_actor =
      opts
      |> Keyword.put(:actor, actor || system_actor())
      |> Keyword.put(:authorize?, false)
      |> Keyword.put(:tenant, tenant)

    AshPackages.deliver(package_id, download_token, opts_with_actor)
  end

  @doc """
  Revokes a package, preventing further delivery or activation.
  """
  @spec revoke(String.t(), keyword()) :: {:ok, OnboardingPackage.t()} | {:error, atom()}
  def revoke(package_id, opts \\ []) do
    actor = Keyword.get(opts, :actor)
    tenant = require_tenant!(opts)

    opts_with_actor =
      opts
      |> Keyword.put(:actor, actor || system_actor())
      |> Keyword.put(:authorize?, false)
      |> Keyword.put(:tenant, tenant)

    AshPackages.revoke(package_id, opts_with_actor)
  end

  @doc """
  Soft-deletes a package.
  """
  @spec delete(String.t(), keyword()) :: {:ok, OnboardingPackage.t()} | {:error, atom()}
  def delete(package_id, opts \\ []) do
    actor = Keyword.get(opts, :actor)
    tenant = require_tenant!(opts)

    opts_with_actor =
      opts
      |> Keyword.put(:actor, actor || system_actor())
      |> Keyword.put(:authorize?, false)
      |> Keyword.put(:tenant, tenant)

    AshPackages.delete(package_id, opts_with_actor)
  end

  @doc """
  Returns default selectors and metadata for package creation.
  """
  @spec defaults() :: %{selectors: [String.t()], metadata: map(), security_mode: String.t()}
  def defaults do
    AshPackages.defaults()
  end

  @doc """
  Returns the configured security mode from the environment.
  Defaults to "mtls" for docker deployments.
  """
  @spec configured_security_mode() :: String.t()
  def configured_security_mode do
    AshPackages.configured_security_mode()
  end

  # Private helpers

  defp normalize_filters(filters) do
    filters
    |> maybe_convert_statuses()
    |> maybe_convert_component_types()
  end

  defp maybe_convert_statuses(%{status: statuses} = filters) when is_list(statuses) do
    converted = Enum.map(statuses, &to_atom_if_string/1)
    Map.put(filters, :status, converted)
  end

  defp maybe_convert_statuses(filters), do: filters

  defp maybe_convert_component_types(%{component_type: types} = filters) when is_list(types) do
    converted = Enum.map(types, &to_atom_if_string/1)
    Map.put(filters, :component_type, converted)
  end

  defp maybe_convert_component_types(filters), do: filters

  defp to_atom_if_string(value) when is_binary(value), do: String.to_existing_atom(value)
  defp to_atom_if_string(value), do: value

  defp system_actor do
    %{
      id: "00000000-0000-0000-0000-000000000000",
      email: "system@serviceradar.local",
      role: :super_admin
    }
  end

  defp require_tenant!(opts) do
    case Keyword.fetch(opts, :tenant) do
      {:ok, tenant} -> normalize_tenant!(tenant)
      :error -> raise ArgumentError, "tenant is required for onboarding packages"
    end
  end

  defp normalize_tenant!(%Tenant{} = tenant), do: tenant

  defp normalize_tenant!(tenant) when is_binary(tenant) and String.starts_with?(tenant, "tenant_") do
    tenant
  end

  defp normalize_tenant!(tenant_id) when is_binary(tenant_id) do
    case Ash.get(Tenant, tenant_id, authorize?: false) do
      {:ok, %Tenant{} = tenant} -> tenant
      _ -> raise ArgumentError, "tenant not found for onboarding packages"
    end
  end

  defp normalize_tenant!(_tenant) do
    raise ArgumentError, "invalid tenant for onboarding packages"
  end
end
