defmodule ServiceRadar.GatewayRegistrationWorker do
  @moduledoc """
  GenServer that handles agent gateway registration at the platform level.

  Unlike pollers (which are tenant-scoped), agent gateways are platform
  infrastructure that serve all tenants. This worker registers the gateway
  with `ServiceRadar.GatewayTracker` for cluster-wide visibility.

  ## Configuration

      {ServiceRadar.GatewayRegistrationWorker, [
        gateway_id: "gateway-001",
        partition: "default",
        domain: "default"
      ]}
  """

  use GenServer

  require Logger

  @heartbeat_interval :timer.seconds(30)

  defstruct [:gateway_id, :partition, :domain, :status, :registered_at]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    gateway_id = Keyword.fetch!(opts, :gateway_id)
    partition = Keyword.get(opts, :partition, "default")
    domain = Keyword.get(opts, :domain, "default")

    state = %__MODULE__{
      gateway_id: gateway_id,
      partition: partition,
      domain: domain,
      status: :available,
      registered_at: DateTime.utc_now()
    }

    # Register with platform-level tracker
    metadata = %{
      partition: partition,
      domain: domain,
      node: Node.self(),
      status: :available,
      registered_at: state.registered_at
    }

    Logger.info(
      "[GatewayRegistrationWorker] Registering gateway: #{gateway_id} partition=#{partition} domain=#{domain} node=#{Node.self()}"
    )

    case ServiceRadar.GatewayTracker.register(gateway_id, metadata) do
      :ok ->
        Logger.info("[GatewayRegistrationWorker] Gateway registered successfully: #{gateway_id}")

      error ->
        Logger.error("[GatewayRegistrationWorker] Failed to register gateway: #{inspect(error)}")
    end

    schedule_heartbeat()
    {:ok, state}
  end

  @impl true
  def handle_info(:heartbeat, state) do
    # Re-register on heartbeat to ensure visibility even if initial registration failed
    metadata = %{
      partition: state.partition,
      domain: state.domain,
      node: Node.self(),
      status: state.status,
      registered_at: state.registered_at
    }

    ServiceRadar.GatewayTracker.register(state.gateway_id, metadata)
    schedule_heartbeat()
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def handle_call(:get_status, _from, state) do
    {:reply, state.status, state}
  end

  @impl true
  def handle_call({:set_status, new_status}, _from, state) do
    Logger.info("Gateway status changed: #{state.status} -> #{new_status}")
    new_state = %{state | status: new_status}

    # Re-register with new status
    metadata = %{
      partition: state.partition,
      domain: state.domain,
      node: Node.self(),
      status: new_status,
      registered_at: state.registered_at
    }

    ServiceRadar.GatewayTracker.register(state.gateway_id, metadata)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call(:get_info, _from, state) do
    info = %{
      gateway_id: state.gateway_id,
      partition: state.partition,
      domain: state.domain,
      node: Node.self(),
      status: state.status,
      registered_at: state.registered_at
    }

    {:reply, info, state}
  end

  @impl true
  def terminate(_reason, state) do
    Logger.info("Gateway unregistering: #{state.gateway_id}")
    ServiceRadar.GatewayTracker.unregister(state.gateway_id)
    :ok
  end

  # Public API

  @doc """
  Get the current gateway status.
  """
  @spec get_status() :: atom()
  def get_status do
    GenServer.call(__MODULE__, :get_status)
  end

  @doc """
  Set the gateway status.
  """
  @spec set_status(atom()) :: :ok
  def set_status(status) when status in [:available, :busy, :unavailable, :draining] do
    GenServer.call(__MODULE__, {:set_status, status})
  end

  @doc """
  Get gateway information.
  """
  @spec get_info() :: map()
  def get_info do
    GenServer.call(__MODULE__, :get_info)
  end

  # Private functions

  defp schedule_heartbeat do
    Process.send_after(self(), :heartbeat, @heartbeat_interval)
  end
end
