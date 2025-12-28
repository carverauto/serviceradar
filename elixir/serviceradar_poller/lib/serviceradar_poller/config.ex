defmodule ServiceRadarPoller.Config do
  @moduledoc """
  Configuration store for the poller.

  Stores runtime configuration that can be queried by other poller components.

  ## Tenant Isolation

  For multi-tenant deployments, each tenant's pollers run with:
  - A unique tenant_id that scopes all operations
  - A tenant-derived EPMD cookie (prevents cross-tenant ERTS clustering)
  - Tenant-prefixed NATS channels

  The tenant_id is read from:
  1. `POLLER_TENANT_ID` environment variable
  2. Extracted from the mTLS certificate CN (if using tenant-scoped certs)

  ## Certificate CN Format

  When using per-tenant certificates, the CN has format:
  `<poller_id>.<partition_id>.<tenant_slug>.serviceradar`

  The tenant_slug is extracted and used for:
  - Horde registry namespacing
  - NATS channel prefixing
  - Audit logging
  """

  use GenServer

  require Logger

  @type config :: %{
          partition_id: String.t(),
          poller_id: String.t(),
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

  @spec poller_id() :: String.t()
  def poller_id do
    GenServer.call(__MODULE__, :poller_id)
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
  Returns the tenant ID for this poller.

  In multi-tenant mode, all operations are scoped to this tenant.
  Returns nil for single-tenant deployments.
  """
  @spec tenant_id() :: String.t() | nil
  def tenant_id do
    GenServer.call(__MODULE__, :tenant_id)
  end

  @doc """
  Returns the tenant slug for this poller.

  The slug is extracted from the certificate CN and used for
  NATS channel prefixing and Horde registry keys.
  """
  @spec tenant_slug() :: String.t() | nil
  def tenant_slug do
    GenServer.call(__MODULE__, :tenant_slug)
  end

  @doc """
  Returns the NATS channel prefix for this poller.

  In multi-tenant mode, returns the tenant slug.
  In single-tenant mode, returns an empty string.
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

      iex> Config.nats_channel("pollers.heartbeat")
      "tenant-acme.pollers.heartbeat"  # multi-tenant

      iex> Config.nats_channel("pollers.heartbeat")
      "pollers.heartbeat"  # single-tenant
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

  In multi-tenant mode, includes tenant_slug in the key tuple.
  This prevents cross-tenant process collisions.

  ## Examples

      iex> Config.registry_key(:device, "partition-1", "10.0.0.1")
      {"tenant-acme", "partition-1", "10.0.0.1"}  # multi-tenant

      iex> Config.registry_key(:device, "partition-1", "10.0.0.1")
      {"default", "partition-1", "10.0.0.1"}  # single-tenant
  """
  @spec registry_key(atom(), String.t(), String.t()) :: tuple()
  def registry_key(_type, partition_id, identifier) do
    tenant = tenant_slug() || "default"
    {tenant, partition_id, identifier}
  end

  # Server callbacks

  @impl true
  def init(opts) do
    partition_id = Keyword.fetch!(opts, :partition_id)
    poller_id = Keyword.fetch!(opts, :poller_id)
    domain = Keyword.fetch!(opts, :domain)
    capabilities = Keyword.get(opts, :capabilities, [])

    # Get tenant info from environment or certificate
    {tenant_id, tenant_slug} = resolve_tenant_info(opts)

    # Build NATS prefix
    nats_prefix = if tenant_slug, do: tenant_slug, else: ""

    config = %{
      partition_id: partition_id,
      poller_id: poller_id,
      domain: domain,
      capabilities: capabilities,
      tenant_id: tenant_id,
      tenant_slug: tenant_slug,
      nats_prefix: nats_prefix
    }

    if tenant_slug do
      Logger.info("Poller configured for tenant: #{tenant_slug} (ID: #{tenant_id || "unknown"})")
    else
      Logger.info("Poller configured in single-tenant mode")
    end

    {:ok, config}
  end

  @impl true
  def handle_call(:get, _from, config) do
    {:reply, config, config}
  end

  def handle_call(:partition_id, _from, config) do
    {:reply, config.partition_id, config}
  end

  def handle_call(:poller_id, _from, config) do
    {:reply, config.poller_id, config}
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
      env_tenant_id = System.get_env("POLLER_TENANT_ID")
      env_tenant_slug = System.get_env("POLLER_TENANT_SLUG")

      if env_tenant_id || env_tenant_slug do
        {env_tenant_id, env_tenant_slug}
      else
        # Priority 3: Extract from certificate CN (if available)
        extract_tenant_from_cert()
      end
    end
  end

  # Extract tenant from certificate CN
  # CN format: <poller_id>.<partition_id>.<tenant_slug>.serviceradar
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
