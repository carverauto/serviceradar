defmodule ServiceRadarAgentGateway.Config do
  @moduledoc """
  Configuration store for the agent gateway.

  Stores runtime configuration that can be queried by other gateway components.

  ## Tenant Isolation

  For multi-tenant deployments, each tenant's gateways run with:
  - A unique tenant_id that scopes all operations
  - A tenant-derived EPMD cookie (prevents cross-tenant ERTS clustering)
  - Tenant-prefixed NATS channels

  The tenant_id is read from:
  1. `GATEWAY_TENANT_ID` environment variable
  2. Extracted from the mTLS certificate CN (if using tenant-scoped certs)

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

    # Get tenant info from environment or certificate
    # System is always multi-tenant - default tenant is used if none specified
    {tenant_id, tenant_slug} = resolve_tenant_info(opts)
    tenant_slug = tenant_slug || "default"
    tenant_id = tenant_id || "00000000-0000-0000-0000-000000000000"

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
      env_tenant_id = System.get_env("GATEWAY_TENANT_ID") || System.get_env("POLLER_TENANT_ID")
      env_tenant_slug = System.get_env("GATEWAY_TENANT_SLUG") || System.get_env("POLLER_TENANT_SLUG")

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
end
