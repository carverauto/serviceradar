defmodule ServiceRadarWebNG.Edge.OnboardingPackages do
  @moduledoc """
  Context module for edge onboarding package operations.

  Delegates to ServiceRadar.Edge.OnboardingPackages Ash-based implementation
  while maintaining backwards compatibility with existing callers.

  This is a single-deployment instance - schema context is implicit from the
  PostgreSQL search_path set by infrastructure.
  """

  alias ServiceRadar.Edge.OnboardingPackage
  alias ServiceRadar.Edge.OnboardingPackages, as: AshPackages
  alias ServiceRadar.Events.AuditWriter
  alias ServiceRadar.Security.RateLimiter
  alias ServiceRadarWebNG.Edge.GatewayCertificateIssuer
  alias ServiceRadarWebNG.Edge.PubSub, as: EdgePubSub

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
    filters = normalize_filters(filters)
    opts = build_opts(opts)

    AshPackages.list!(filters, opts)
  end

  @doc """
  Gets a single package by ID.

  Returns `{:ok, package}` or `{:error, :not_found}`.
  """
  @spec get(String.t(), keyword()) :: {:ok, OnboardingPackage.t()} | {:error, :not_found}
  def get(id, opts \\ [])

  def get(id, opts) when is_binary(id) do
    opts = build_opts(opts)
    AshPackages.get(id, opts)
  end

  def get(_, _opts), do: {:error, :not_found}

  @doc """
  Gets a single package by ID, raising if not found.
  """
  @spec get!(String.t(), keyword()) :: OnboardingPackage.t()
  def get!(id, opts \\ []) do
    opts = build_opts(opts)
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
          {:ok, %{package: OnboardingPackage.t(), join_token: String.t(), download_token: String.t()}}
          | {:error, Ash.Error.t()}
  def create(attrs, opts \\ []) do
    opts = build_opts(opts)

    case AshPackages.create(attrs, opts) do
      {:ok, %{package: package} = result} ->
        EdgePubSub.broadcast_package_created(package)
        {:ok, result}

      other ->
        other
    end
  end

  @doc """
  Creates an edge onboarding package with automatic platform certificate generation.

  This is the preferred method for production deployments. It automatically:
  1. Gets or generates the platform's intermediate CA (on first use)
  2. Generates a component certificate signed by the platform CA
  3. Includes the encrypted certificate bundle in the package

  In the current single-deployment setup, this may return `{:error, :ca_not_available}`
  when platform-side certificate issuance is not enabled.

  The certificate CN follows the format: `<component_id>.<partition_id>.serviceradar`

  ## Options

    * `:partition_id` - Network partition identifier (default: "default")
    * `:cert_validity_days` - Component certificate validity (default: 1)
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

      iex> create_with_platform_cert(
      ...>   %{label: "prod-gateway-01", component_type: :gateway},
      ...>   actor: current_user
      ...> )
      {:ok, %{package: %OnboardingPackage{}, certificate_data: %{...}}}

  """
  @spec create_with_platform_cert(map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def create_with_platform_cert(attrs, opts \\ []) do
    opts = build_opts(opts)
    AshPackages.create_with_platform_cert(attrs, opts)
  end

  @doc """
  Creates an agent onboarding package using a gateway-issued mTLS bundle.
  """
  @spec create_with_gateway_cert(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def create_with_gateway_cert(attrs, opts \\ []) do
    opts = build_opts(opts)

    gateway_id = Map.get(attrs, :gateway_id)
    component_id = Map.get(attrs, :component_id)
    partition_id = attrs |> partition_attr_value() |> normalize_partition_id() || "default"
    attrs = attrs |> Map.put(:partition_id, partition_id) |> Map.put(:site, partition_id)

    with true <- (is_binary(gateway_id) and gateway_id != "") or {:error, :gateway_unavailable},
         true <- (is_binary(component_id) and component_id != "") or {:error, :invalid_identity},
         :ok <- authorize_partition(partition_id, opts),
         :ok <- enforce_issuance_quota(component_id, partition_id, opts),
         {:ok, bundle} <-
           GatewayCertificateIssuer.issue_agent_bundle(
             gateway_id,
             component_id,
             partition_id,
             opts
             |> Keyword.put(:authorized_component_id, component_id)
             |> Keyword.put(:authorized_partition_id, actor_partition_id(opts))
             |> Keyword.put(:audit_actor, Keyword.get(opts, :actor))
           ),
         {:ok, result} = ok <-
           AshPackages.create_with_bundle(attrs, bundle.bundle_pem, bundle, opts) do
      EdgePubSub.broadcast_package_created(result.package)
      ok
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
          {:ok, %{package: OnboardingPackage.t(), join_token: String.t(), bundle_pem: String.t() | nil}}
          | {:error, atom()}
  def deliver(package_id, download_token, opts \\ []) do
    opts = build_opts(opts)

    case AshPackages.deliver(package_id, download_token, opts) do
      {:ok, %{package: package} = result} ->
        EdgePubSub.broadcast_package_updated(package)
        {:ok, result}

      other ->
        other
    end
  end

  @doc """
  Revokes a package, preventing further delivery or activation.
  """
  @spec revoke(String.t(), keyword()) :: {:ok, OnboardingPackage.t()} | {:error, atom()}
  def revoke(package_id, opts \\ []) do
    opts = build_opts(opts)

    case AshPackages.revoke(package_id, opts) do
      {:ok, package} ->
        EdgePubSub.broadcast_package_updated(package)
        {:ok, package}

      other ->
        other
    end
  end

  @doc """
  Soft-deletes a package.
  """
  @spec delete(String.t(), keyword()) :: {:ok, OnboardingPackage.t()} | {:error, atom()}
  def delete(package_id, opts \\ []) do
    opts = build_opts(opts)

    case AshPackages.delete(package_id, opts) do
      {:ok, package} ->
        EdgePubSub.broadcast_package_deleted(package)
        {:ok, package}

      other ->
        other
    end
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

  defp build_opts(opts) do
    authorize? = Keyword.get(opts, :authorize?, true)
    actor = Keyword.get(opts, :actor)

    if authorize? && is_nil(actor) do
      raise ArgumentError,
            "edge onboarding operations require an explicit :actor (set authorize?: false for token-gated flows)"
    end

    opts
  end

  defp authorize_partition(partition_id, opts) do
    actor_partition_id = actor_partition_id(opts)

    cond do
      is_nil(actor_partition_id) -> :ok
      actor_partition_id == partition_id -> :ok
      true -> {:error, :partition_not_authorized}
    end
  end

  defp actor_partition_id(opts) do
    opts
    |> Keyword.get(:actor)
    |> case do
      %{partition_id: partition_id} -> normalize_partition_id(partition_id)
      %{"partition_id" => partition_id} -> normalize_partition_id(partition_id)
      _actor -> nil
    end
  end

  defp enforce_issuance_quota(component_id, partition_id, opts) do
    quota_opts = Keyword.get(opts, :issuance_quota, [])

    cond do
      Keyword.get(quota_opts, :enabled, true) == false ->
        :ok

      quota_override_authorized?(opts) ->
        audit_quota_override(component_id, partition_id, opts)
        :ok

      true ->
        check_issuance_quota(partition_id, opts, quota_opts)
    end
  end

  defp check_issuance_quota(partition_id, opts, quota_opts) do
    actor = Keyword.get(opts, :actor)

    with :ok <-
           check_rate_limit(
             :edge_onboarding_package_create_actor,
             {:actor, actor_identifier(actor)},
             Keyword.get(quota_opts, :actor_rate_limit, [])
           ) do
      check_rate_limit(
        :edge_onboarding_package_create_partition,
        {:partition, normalize_partition_id(partition_id)},
        Keyword.get(quota_opts, :partition_rate_limit, [])
      )
    end
  end

  defp check_rate_limit(bucket, key, rate_limit_opts) do
    case RateLimiter.check_and_record(bucket, key, rate_limit_opts) do
      :ok -> :ok
      {:error, retry_after} -> {:error, {:edge_onboarding_quota_exceeded, bucket, retry_after}}
    end
  end

  defp quota_override_authorized?(opts) do
    opts
    |> Keyword.get(:quota_override_by)
    |> admin_or_system_actor?()
  end

  defp admin_or_system_actor?(%{role: role}) when role in [:admin, :system, "admin", "system"], do: true

  defp admin_or_system_actor?(%{"role" => role}) when role in [:admin, :system, "admin", "system"], do: true

  defp admin_or_system_actor?(_actor), do: false

  defp audit_quota_override(component_id, partition_id, opts) do
    actor = Keyword.get(opts, :actor)
    override_actor = Keyword.get(opts, :quota_override_by)

    AuditWriter.write_async(
      action: :edge_onboarding_quota_override,
      resource_type: "edge_onboarding_package",
      resource_id: component_id,
      resource_name: component_id,
      actor: override_actor,
      severity: :medium,
      details: %{
        actor_id: actor_identifier(actor),
        partition_id: normalize_partition_id(partition_id),
        component_id: component_id,
        override_actor_id: actor_identifier(override_actor)
      }
    )
  end

  defp actor_identifier(%{id: id}) when not is_nil(id), do: to_string(id)
  defp actor_identifier(%{"id" => id}) when not is_nil(id), do: to_string(id)
  defp actor_identifier(actor) when is_binary(actor), do: actor
  defp actor_identifier(nil), do: "unknown"
  defp actor_identifier(_actor), do: "unknown"

  defp normalize_partition_id(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp normalize_partition_id(nil), do: nil

  defp normalize_partition_id(value) when is_atom(value), do: value |> Atom.to_string() |> normalize_partition_id()

  defp normalize_partition_id(_value), do: nil

  defp partition_attr_value(attrs) do
    Map.get(attrs, :partition_id) ||
      Map.get(attrs, "partition_id") ||
      Map.get(attrs, :site) ||
      Map.get(attrs, "site")
  end

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
end
