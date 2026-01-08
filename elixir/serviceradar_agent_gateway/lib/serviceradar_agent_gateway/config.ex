defmodule ServiceRadarAgentGateway.Config do
  @moduledoc """
  Configuration store for the agent gateway.

  Stores runtime configuration that can be queried by other gateway components.

  ## Tenant Isolation

  For multi-tenant deployments, each tenant's gateways run with:
  - A unique tenant_id that scopes all operations
  - A tenant-derived EPMD cookie (prevents cross-tenant ERTS clustering)
  - Tenant-prefixed NATS channels

  The tenant_id is resolved in priority order:
  1. `GATEWAY_TENANT_ID` environment variable
  2. `SERVICERADAR_PLATFORM_TENANT_ID` environment variable
  3. **Cluster RPC discovery** - queries core-elx for platform tenant info

  If no tenant_id is configured via environment, the gateway
  will automatically discover it from the core service via cluster RPC.
  This allows the gateway to self-configure without manual environment setup.

  The tenant_slug is resolved in priority order:
  1. `GATEWAY_TENANT_SLUG` environment variable
  2. `SERVICERADAR_PLATFORM_TENANT_SLUG` environment variable
  3. Extracted from the mTLS certificate CN (if using tenant-scoped certs)
  4. Defaults to the platform tenant slug

  ## Certificate CN Format

  When using per-tenant certificates, the CN has format:
  `<gateway_id>.<partition_id>.<tenant_slug>.serviceradar`

  The tenant_slug is extracted and used for:
  - Horde registry namespacing
  - NATS channel prefixing
  - Audit logging
  """

  use GenServer

  require Logger

  @type config :: %{
          partition_id: String.t(),
          gateway_id: String.t(),
          domain: String.t(),
          capabilities: [atom()],
          tenant_id: String.t() | nil,
          tenant_slug: String.t() | nil,
          nats_prefix: String.t()
        }

  # Client API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec get() :: config()
  def get do
    GenServer.call(__MODULE__, :get)
  end

  @spec partition_id() :: String.t()
  def partition_id do
    GenServer.call(__MODULE__, :partition_id)
  end

  @spec gateway_id() :: String.t()
  def gateway_id do
    GenServer.call(__MODULE__, :gateway_id)
  end

  @spec domain() :: String.t()
  def domain do
    GenServer.call(__MODULE__, :domain)
  end

  @spec capabilities() :: [atom()]
  def capabilities do
    GenServer.call(__MODULE__, :capabilities)
  end

  @doc """
  Returns the tenant ID for this gateway.

  All operations are scoped to this tenant. Defaults to the
  default tenant UUID if not explicitly configured.
  """
  @spec tenant_id() :: String.t()
  def tenant_id do
    GenServer.call(__MODULE__, :tenant_id)
  end

  @doc """
  Returns the tenant slug for this gateway.

  The slug is used for NATS channel prefixing and Horde registry keys.
  Defaults to "default" if not explicitly configured.
  """
  @spec tenant_slug() :: String.t()
  def tenant_slug do
    GenServer.call(__MODULE__, :tenant_slug)
  end

  @doc """
  Returns the NATS channel prefix for this gateway.

  Returns the tenant slug, which prefixes all NATS channels for tenant isolation.
  """
  @spec nats_prefix() :: String.t()
  def nats_prefix do
    GenServer.call(__MODULE__, :nats_prefix)
  end

  @doc """
  Get a specific config value by key.
  """
  @spec get(atom()) :: any()
  def get(key) when is_atom(key) do
    GenServer.call(__MODULE__, {:get, key})
  end

  @doc """
  Returns a NATS channel name with the tenant prefix applied.

  ## Examples

      iex> Config.nats_channel("gateways.heartbeat")
      "tenant-acme.gateways.heartbeat"  # multi-tenant

      iex> Config.nats_channel("gateways.heartbeat")
      "gateways.heartbeat"  # single-tenant
  """
  @spec nats_channel(String.t()) :: String.t()
  def nats_channel(base_channel) do
    case nats_prefix() do
      "" -> base_channel
      prefix -> "#{prefix}.#{base_channel}"
    end
  end

  @doc """
  Builds a Horde registry key with tenant scope.

  Includes tenant_slug in the key tuple to prevent cross-tenant process collisions.

  ## Examples

      iex> Config.registry_key(:device, "partition-1", "10.0.0.1")
      {"tenant-acme", "partition-1", "10.0.0.1"}

      iex> Config.registry_key(:device, "partition-1", "10.0.0.1")
      {"default", "partition-1", "10.0.0.1"}  # default tenant
  """
  @spec registry_key(atom(), String.t(), String.t()) :: tuple()
  def registry_key(_type, partition_id, identifier) do
    {tenant_slug(), partition_id, identifier}
  end

  # Server callbacks

  @impl true
  def init(opts) do
    partition_id = Keyword.fetch!(opts, :partition_id)
    gateway_id = Keyword.fetch!(opts, :gateway_id)
    domain = Keyword.fetch!(opts, :domain)
    capabilities = Keyword.get(opts, :capabilities, [])

    # Get tenant info from environment, certificate, or cluster RPC
    # System is always multi-tenant - default tenant is used if none specified
    {tenant_id, tenant_slug} = resolve_tenant_info(opts)
    tenant_id = normalize_tenant_id(tenant_id)
    tenant_slug = normalize_tenant_slug(tenant_slug)

    {tenant_id, tenant_slug} =
      if is_nil(tenant_id) do
        # No tenant_id from env/cert - discover via cluster RPC
        Logger.info("No tenant_id configured; discovering from cluster...")
        discover_tenant_from_cluster()
      else
        validate_tenant_id!(tenant_id)
        {tenant_id, tenant_slug || platform_tenant_slug()}
      end

    # Build NATS prefix
    nats_prefix = tenant_slug

    config = %{
      partition_id: partition_id,
      gateway_id: gateway_id,
      domain: domain,
      capabilities: capabilities,
      tenant_id: tenant_id,
      tenant_slug: tenant_slug,
      nats_prefix: nats_prefix
    }

    Logger.info("Gateway configured for tenant: #{tenant_slug} (ID: #{tenant_id})")

    {:ok, config}
  end

  defp normalize_tenant_id(nil), do: nil

  defp normalize_tenant_id(value) do
    value
    |> to_string()
    |> String.trim()
    |> case do
      "" -> nil
      id -> id
    end
  end

  defp normalize_tenant_slug(nil), do: nil

  defp normalize_tenant_slug(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> case do
      "" ->
        nil

      slug ->
        if Regex.match?(~r/^[a-z0-9-]{1,63}$/, slug) do
          slug
        else
          raise "invalid tenant_slug format for agent gateway"
        end
    end
  end

  defp validate_tenant_id!(tenant_id) do
    if not Regex.match?(~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i, tenant_id) do
      raise "invalid tenant_id format for agent gateway"
    end

    if tenant_id == "00000000-0000-0000-0000-000000000000" do
      raise "invalid tenant_id for agent gateway: platform tenant must not be the zero UUID"
    end
  end

  # Discover tenant info from core via cluster RPC with retries
  @discovery_max_attempts 30
  @discovery_retry_interval_ms 2_000

  defp discover_tenant_from_cluster do
    discover_tenant_from_cluster(1)
  end

  defp discover_tenant_from_cluster(attempt) when attempt > @discovery_max_attempts do
    raise "failed to discover platform tenant from cluster after #{@discovery_max_attempts} attempts"
  end

  defp discover_tenant_from_cluster(attempt) do
    case find_core_node() do
      nil ->
        Logger.debug("No core node found (attempt #{attempt}/#{@discovery_max_attempts}), retrying...")
        Process.sleep(@discovery_retry_interval_ms)
        discover_tenant_from_cluster(attempt + 1)

      core_node ->
        case rpc_get_platform_tenant(core_node) do
          {:ok, %{tenant_id: tenant_id, tenant_slug: tenant_slug}} ->
            validate_tenant_id!(tenant_id)
            Logger.info("Discovered platform tenant from #{core_node}: #{tenant_slug} (#{tenant_id})")
            {tenant_id, tenant_slug}

          {:error, :not_ready} ->
            Logger.debug("Core node #{core_node} not ready (attempt #{attempt}/#{@discovery_max_attempts}), retrying...")
            Process.sleep(@discovery_retry_interval_ms)
            discover_tenant_from_cluster(attempt + 1)

          {:error, reason} ->
            Logger.warning("RPC to #{core_node} failed: #{inspect(reason)} (attempt #{attempt}/#{@discovery_max_attempts})")
            Process.sleep(@discovery_retry_interval_ms)
            discover_tenant_from_cluster(attempt + 1)
        end
    end
  end

  defp find_core_node do
    # Look for a core-elx node in the cluster
    Node.list()
    |> Enum.find(fn node ->
      node_str = Atom.to_string(node)
      String.contains?(node_str, "serviceradar_core")
    end)
  end

  defp rpc_get_platform_tenant(node) do
    case :rpc.call(node, ServiceRadar.Edge.AgentGatewaySync, :get_platform_tenant_info, [], 5_000) do
      {:badrpc, reason} ->
        {:error, reason}

      result ->
        result
    end
  end

  @impl true
  def handle_call(:get, _from, config) do
    {:reply, config, config}
  end

  def handle_call(:partition_id, _from, config) do
    {:reply, config.partition_id, config}
  end

  def handle_call(:gateway_id, _from, config) do
    {:reply, config.gateway_id, config}
  end

  def handle_call(:domain, _from, config) do
    {:reply, config.domain, config}
  end

  def handle_call(:capabilities, _from, config) do
    {:reply, config.capabilities, config}
  end

  def handle_call(:tenant_id, _from, config) do
    {:reply, config.tenant_id, config}
  end

  def handle_call(:tenant_slug, _from, config) do
    {:reply, config.tenant_slug, config}
  end

  def handle_call(:nats_prefix, _from, config) do
    {:reply, config.nats_prefix, config}
  end

  # Resolve tenant info from environment or certificate
  defp resolve_tenant_info(opts) do
    # Priority 1: Explicit tenant_id/tenant_slug from opts
    tenant_id = Keyword.get(opts, :tenant_id)
    tenant_slug = Keyword.get(opts, :tenant_slug)

    if tenant_id || tenant_slug do
      {tenant_id, tenant_slug}
    else
      # Priority 2: Environment variables
      env_tenant_id =
        System.get_env("GATEWAY_TENANT_ID") ||
          System.get_env("SERVICERADAR_PLATFORM_TENANT_ID") ||
          System.get_env("PLATFORM_TENANT_ID")

      env_tenant_slug =
        System.get_env("GATEWAY_TENANT_SLUG") ||
          System.get_env("SERVICERADAR_PLATFORM_TENANT_SLUG") ||
          System.get_env("PLATFORM_TENANT_SLUG")

      if env_tenant_id || env_tenant_slug do
        {env_tenant_id, env_tenant_slug}
      else
        # Priority 3: Extract from certificate CN (if available)
        extract_tenant_from_cert()
      end
    end
  end

  # Extract tenant from certificate CN
  # CN format: <gateway_id>.<partition_id>.<tenant_slug>.serviceradar
  defp extract_tenant_from_cert do
    cert_dir = System.get_env("CERT_DIR", "/etc/serviceradar/certs")
    cert_file = Path.join(cert_dir, "svid.pem")

    case File.read(cert_file) do
      {:ok, pem} ->
        case extract_cn_from_pem(pem) do
          {:ok, cn} ->
            case parse_tenant_from_cn(cn) do
              {:ok, %{tenant_slug: slug}} -> {nil, slug}
              _ -> {nil, nil}
            end

          _ ->
            {nil, nil}
        end

      _ ->
        {nil, nil}
    end
  end

  defp extract_cn_from_pem(pem) do
    case :public_key.pem_decode(pem) do
      [{:Certificate, der, _} | _] ->
        case :public_key.pkix_decode_cert(der, :otp) do
          {:OTPCertificate, tbs_cert, _, _} ->
            extract_cn_from_tbs(tbs_cert)

          _ ->
            {:error, :invalid_cert}
        end

      _ ->
        {:error, :no_cert}
    end
  end

  defp extract_cn_from_tbs(tbs_cert) do
    subject = elem(tbs_cert, 6)

    case subject do
      {:rdnSequence, rdns} ->
        cn =
          rdns
          |> List.flatten()
          |> Enum.find_value(fn
            {:AttributeTypeAndValue, {2, 5, 4, 3}, {:utf8String, cn}} -> cn
            {:AttributeTypeAndValue, {2, 5, 4, 3}, {:printableString, cn}} -> List.to_string(cn)
            _ -> nil
          end)

        if cn, do: {:ok, cn}, else: {:error, :no_cn}

      _ ->
        {:error, :invalid_subject}
    end
  end

  # Parse tenant from CN
  # Format: <component_id>.<partition_id>.<tenant_slug>.serviceradar
  defp parse_tenant_from_cn(cn) do
    case String.split(cn, ".") do
      [_component_id, _partition_id, tenant_slug, "serviceradar"] ->
        {:ok, %{tenant_slug: tenant_slug}}

      _ ->
        {:error, :invalid_cn_format}
    end
  end

  defp platform_tenant_slug do
    Application.get_env(:serviceradar_core, :platform_tenant_slug, "platform")
  end
end
