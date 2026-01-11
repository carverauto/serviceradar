defmodule ServiceRadar.Gateway.RegistrationWorker do
  @moduledoc """
  GenServer that handles gateway auto-registration with the Horde registry.

  When a gateway node starts, this worker:
  1. Registers the entity with ServiceRadar.GatewayRegistry
  2. Broadcasts registration event via PubSub
  3. Maintains heartbeat to update status periodically

  ## Configuration

  Start with partition and domain configuration:

      {ServiceRadar.Gateway.RegistrationWorker, [
        partition_id: "partition-1",
        domain: "site-a"
      ]}

  For gateways, set entity_type to :gateway for proper log messages:

      {ServiceRadar.Gateway.RegistrationWorker, [
        partition_id: "partition-1",
        domain: "site-a",
        entity_type: :gateway
      ]}

  Note: Gateways do not have capabilities. They orchestrate monitoring jobs
  by receiving scheduled tasks and dispatching work to available agents.
  Agents have capabilities (ICMP, TCP, process checks, gRPC to external checkers).

  ## Status Values

  - `:available` - Ready to accept jobs
  - `:busy` - Currently executing jobs
  - `:unavailable` - Manually marked unavailable
  - `:draining` - Finishing current jobs before shutdown
  """

  use GenServer

  require Logger

  @heartbeat_interval :timer.seconds(30)
  @stale_threshold :timer.minutes(2)

  defstruct [:tenant_id, :partition_id, :gateway_id, :domain, :status, :registered_at, :entity_type]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    tenant_id = Keyword.get(opts, :tenant_id, default_tenant_id())
    partition_id = Keyword.fetch!(opts, :partition_id)
    entity_type = Keyword.get(opts, :entity_type, :gateway)
    gateway_id = Keyword.get(opts, :gateway_id, generate_entity_id(entity_type))
    domain = Keyword.get(opts, :domain, "default")

    state = %__MODULE__{
      tenant_id: tenant_id,
      partition_id: partition_id,
      gateway_id: gateway_id,
      domain: domain,
      status: :available,
      registered_at: DateTime.utc_now(),
      entity_type: entity_type
    }

    entity_label = entity_type_label(entity_type)

    # Register with Horde on startup
    case register_gateway(state) do
      {:ok, _pid} ->
        Logger.info(
          "#{entity_label} registered: tenant=#{tenant_id} partition=#{partition_id} domain=#{domain} node=#{Node.self()}"
        )

        schedule_heartbeat()
        {:ok, state}

      {:error, reason} ->
        Logger.error("Failed to register #{String.downcase(entity_label)}: #{inspect(reason)}")
        {:stop, reason}
    end
  end

  @impl true
  def handle_info(:heartbeat, state) do
    update_heartbeat(state)
    schedule_heartbeat()
    {:noreply, state}
  end

  @impl true
  def handle_info({:nodedown, node}, state) do
    Logger.warning("Node down detected: #{node}")
    {:noreply, state}
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    {:reply, state.status, state}
  end

  @impl true
  def handle_call({:set_status, new_status}, _from, state) do
    entity_label = entity_type_label(state.entity_type)
    Logger.info("#{entity_label} status changed: #{state.status} -> #{new_status}")

    new_state = %{state | status: new_status}
    update_status(new_state)

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call(:get_info, _from, state) do
    info = %{
      tenant_id: state.tenant_id,
      partition_id: state.partition_id,
      domain: state.domain,
      node: Node.self(),
      status: state.status,
      registered_at: state.registered_at
    }

    {:reply, info, state}
  end

  @impl true
  def terminate(_reason, state) do
    entity_label = entity_type_label(state.entity_type)
    Logger.info("#{entity_label} unregistering: #{state.gateway_id} for tenant: #{state.tenant_id}")
    ServiceRadar.GatewayRegistry.unregister_gateway(state.tenant_id, state.gateway_id)

    Phoenix.PubSub.broadcast(
      ServiceRadar.PubSub,
      "gateway:registrations:#{state.tenant_id}",
      {:gateway_unregistered, state.gateway_id}
    )

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

  ## Examples

      ServiceRadar.Gateway.RegistrationWorker.set_status(:unavailable)
      ServiceRadar.Gateway.RegistrationWorker.set_status(:available)
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

  @doc """
  Mark gateway as unavailable (for admin control).
  """
  @spec mark_unavailable() :: :ok
  def mark_unavailable do
    set_status(:unavailable)
  end

  @doc """
  Mark gateway as available.
  """
  @spec mark_available() :: :ok
  def mark_available do
    set_status(:available)
  end

  # Private functions

  defp register_gateway(state) do
    metadata = %{
      partition_id: state.partition_id,
      domain: state.domain,
      node: Node.self(),
      status: state.status,
      entity_type: state.entity_type
    }

    # Use the new tenant-scoped registration API
    ServiceRadar.GatewayRegistry.register_gateway(state.tenant_id, state.gateway_id, metadata)
  end

  defp update_heartbeat(state) do
    ServiceRadar.GatewayRegistry.heartbeat(state.tenant_id, state.gateway_id)
  end

  defp update_status(state) do
    # Update status via TenantRegistry
    ServiceRadar.Cluster.TenantRegistry.update_value(
      state.tenant_id,
      {:gateway, state.gateway_id},
      fn meta ->
        %{meta | status: state.status, last_heartbeat: DateTime.utc_now()}
      end
    )

    Phoenix.PubSub.broadcast(
      ServiceRadar.PubSub,
      "gateway:registrations:#{state.tenant_id}",
      {:gateway_status_changed, state.gateway_id, state.status}
    )
  end

  defp schedule_heartbeat do
    Process.send_after(self(), :heartbeat, @heartbeat_interval)
  end

  @doc """
  Check if a gateway is stale (no heartbeat for threshold period).
  """
  @spec stale?(map()) :: boolean()
  def stale?(gateway_metadata) do
    case gateway_metadata[:last_heartbeat] do
      nil ->
        true

      last_heartbeat ->
        diff = DateTime.diff(DateTime.utc_now(), last_heartbeat, :millisecond)
        diff > @stale_threshold
    end
  end

  # Get default tenant ID from environment or config
  defp default_tenant_id do
    System.get_env("GATEWAY_TENANT_ID") ||
      Application.get_env(:serviceradar_core, :default_tenant_id, "00000000-0000-0000-0000-000000000000")
  end

  # Generate a unique entity ID based on type
  defp generate_entity_id(entity_type) do
    hostname =
      case :inet.gethostname() do
        {:ok, name} -> List.to_string(name)
        _ -> "unknown"
      end

    prefix = entity_type_prefix(entity_type)
    "#{prefix}-#{hostname}-#{:rand.uniform(9999)}"
  end

  # Get human-readable label for entity type
  defp entity_type_label(:gateway), do: "Gateway"
  defp entity_type_label(_), do: "Gateway"

  # Get ID prefix for entity type
  defp entity_type_prefix(:gateway), do: "gateway"
  defp entity_type_prefix(_), do: "gateway"
end
