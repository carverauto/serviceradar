defmodule ServiceRadarAgentGateway.Config do
  @moduledoc """
  Configuration store for the agent gateway.

  Stores runtime configuration that can be queried by other gateway components.

  ## Platform Infrastructure

  The agent gateway is platform infrastructure that serves multiple tenants.
  Tenant isolation is handled per-request via mTLS certificates - each connecting
  agent's certificate contains its tenant identity.

  This Config module stores the gateway's own identity (partition, gateway_id, domain)
  but NOT tenant information. Tenant context flows through each gRPC request.
  """

  use GenServer

  require Logger

  @type config :: %{
          partition_id: String.t(),
          gateway_id: String.t(),
          domain: String.t(),
          capabilities: [atom()]
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
  Get a specific config value by key.
  """
  @spec get(atom()) :: any()
  def get(key) when is_atom(key) do
    GenServer.call(__MODULE__, {:get, key})
  end

  # Server callbacks

  @impl true
  def init(opts) do
    partition_id = Keyword.fetch!(opts, :partition_id)
    gateway_id = Keyword.fetch!(opts, :gateway_id)
    domain = Keyword.fetch!(opts, :domain)
    capabilities = Keyword.get(opts, :capabilities, [])

    config = %{
      partition_id: partition_id,
      gateway_id: gateway_id,
      domain: domain,
      capabilities: capabilities
    }

    Logger.info("Gateway configured: #{gateway_id} in partition #{partition_id}, domain #{domain}")

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

  def handle_call({:get, key}, _from, config) do
    {:reply, Map.get(config, key), config}
  end
end
