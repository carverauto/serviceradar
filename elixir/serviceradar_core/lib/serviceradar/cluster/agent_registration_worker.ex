defmodule ServiceRadar.Agent.RegistrationWorker do
  @moduledoc """
  GenServer that handles agent auto-registration with the Horde registry.

  When an agent node starts, this worker:
  1. Registers the agent with ServiceRadar.AgentRegistry
  2. Broadcasts registration event via PubSub
  3. Maintains heartbeat to update status periodically

  ## Configuration

  Start with partition and poller configuration:

      {ServiceRadar.Agent.RegistrationWorker, [
        partition_id: "partition-1",
        agent_id: "agent-001",
        poller_id: "poller-001",
        capabilities: [:snmp, :wmi, :disk]
      ]}

  ## Status Values

  - `:available` - Ready to accept checks
  - `:busy` - Currently executing checks
  - `:unavailable` - Manually marked unavailable
  - `:draining` - Finishing current checks before shutdown
  """

  use GenServer

  require Logger

  @heartbeat_interval :timer.seconds(30)
  @stale_threshold :timer.minutes(2)

  defstruct [:tenant_id, :partition_id, :agent_id, :poller_id, :capabilities, :status, :registered_at]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    tenant_id = Keyword.get(opts, :tenant_id, default_tenant_id())
    partition_id = Keyword.fetch!(opts, :partition_id)
    agent_id = Keyword.fetch!(opts, :agent_id)
    poller_id = Keyword.get(opts, :poller_id)
    capabilities = Keyword.get(opts, :capabilities, [])

    state = %__MODULE__{
      tenant_id: tenant_id,
      partition_id: partition_id,
      agent_id: agent_id,
      poller_id: poller_id,
      capabilities: capabilities,
      status: :available,
      registered_at: DateTime.utc_now()
    }

    # Register with Horde on startup
    case register_agent(state) do
      {:ok, _pid} ->
        Logger.info(
          "Agent registered: tenant=#{tenant_id} partition=#{partition_id} agent_id=#{agent_id} poller=#{poller_id || "none"} node=#{Node.self()}"
        )

        schedule_heartbeat()
        {:ok, state}

      {:error, reason} ->
        Logger.error("Failed to register agent: #{inspect(reason)}")
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
    Logger.info("Agent status changed: #{state.status} -> #{new_status}")

    new_state = %{state | status: new_status}
    update_status(new_state)

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call(:get_info, _from, state) do
    info = %{
      tenant_id: state.tenant_id,
      partition_id: state.partition_id,
      agent_id: state.agent_id,
      poller_id: state.poller_id,
      capabilities: state.capabilities,
      node: Node.self(),
      status: state.status,
      registered_at: state.registered_at
    }

    {:reply, info, state}
  end

  @impl true
  def terminate(_reason, state) do
    Logger.info("Agent unregistering: #{state.agent_id} for tenant: #{state.tenant_id}")
    ServiceRadar.AgentRegistry.unregister_agent(state.tenant_id, state.agent_id)

    Phoenix.PubSub.broadcast(
      ServiceRadar.PubSub,
      "agent:registrations:#{state.tenant_id}",
      {:agent_unregistered, state.agent_id}
    )

    :ok
  end

  # Public API

  @doc """
  Get the current agent status.
  """
  @spec get_status() :: atom()
  def get_status do
    GenServer.call(__MODULE__, :get_status)
  end

  @doc """
  Set the agent status.

  ## Examples

      ServiceRadar.Agent.RegistrationWorker.set_status(:unavailable)
      ServiceRadar.Agent.RegistrationWorker.set_status(:available)
  """
  @spec set_status(atom()) :: :ok
  def set_status(status) when status in [:available, :busy, :unavailable, :draining] do
    GenServer.call(__MODULE__, {:set_status, status})
  end

  @doc """
  Get agent information.
  """
  @spec get_info() :: map()
  def get_info do
    GenServer.call(__MODULE__, :get_info)
  end

  @doc """
  Mark agent as unavailable (for admin control).
  """
  @spec mark_unavailable() :: :ok
  def mark_unavailable do
    set_status(:unavailable)
  end

  @doc """
  Mark agent as available.
  """
  @spec mark_available() :: :ok
  def mark_available do
    set_status(:available)
  end

  # Private functions

  defp register_agent(state) do
    metadata = %{
      partition_id: state.partition_id,
      poller_id: state.poller_id,
      capabilities: state.capabilities,
      node: Node.self(),
      status: state.status
    }

    # Use the new tenant-scoped registration API
    ServiceRadar.AgentRegistry.register_agent(state.tenant_id, state.agent_id, metadata)
  end

  defp update_heartbeat(state) do
    ServiceRadar.AgentRegistry.heartbeat(state.tenant_id, state.agent_id)
  end

  defp update_status(state) do
    # Update status via TenantRegistry
    ServiceRadar.Cluster.TenantRegistry.update_value(
      state.tenant_id,
      {:agent, state.agent_id},
      fn meta ->
        %{meta | status: state.status, last_heartbeat: DateTime.utc_now()}
      end
    )

    Phoenix.PubSub.broadcast(
      ServiceRadar.PubSub,
      "agent:registrations:#{state.tenant_id}",
      {:agent_status_changed, state.agent_id, state.status}
    )
  end

  defp schedule_heartbeat do
    Process.send_after(self(), :heartbeat, @heartbeat_interval)
  end

  @doc """
  Check if an agent is stale (no heartbeat for threshold period).
  """
  @spec stale?(map()) :: boolean()
  def stale?(agent_metadata) do
    case agent_metadata[:last_heartbeat] do
      nil ->
        true

      last_heartbeat ->
        diff = DateTime.diff(DateTime.utc_now(), last_heartbeat, :millisecond)
        diff > @stale_threshold
    end
  end

  # Get default tenant ID from environment or config
  defp default_tenant_id do
    System.get_env("AGENT_TENANT_ID") ||
      Application.get_env(:serviceradar_core, :default_tenant_id, "00000000-0000-0000-0000-000000000000")
  end
end
