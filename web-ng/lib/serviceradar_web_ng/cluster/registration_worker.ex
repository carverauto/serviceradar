defmodule ServiceRadar.Poller.RegistrationWorker do
  @moduledoc """
  GenServer that handles poller auto-registration with the Horde registry.

  When a poller node starts, this worker:
  1. Registers the poller with ServiceRadar.PollerRegistry
  2. Broadcasts registration event via PubSub
  3. Maintains heartbeat to update status periodically

  ## Configuration

  Start with partition and domain configuration:

      {ServiceRadar.Poller.RegistrationWorker, [
        partition_id: "partition-1",
        domain: "site-a",
        capabilities: [:snmp, :grpc, :sweep]
      ]}

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

  defstruct [:partition_id, :domain, :capabilities, :key, :status, :registered_at]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    partition_id = Keyword.fetch!(opts, :partition_id)
    domain = Keyword.get(opts, :domain, "default")
    capabilities = Keyword.get(opts, :capabilities, [])

    state = %__MODULE__{
      partition_id: partition_id,
      domain: domain,
      capabilities: capabilities,
      key: {partition_id, Node.self()},
      status: :available,
      registered_at: DateTime.utc_now()
    }

    # Register with Horde on startup
    case register_poller(state) do
      {:ok, _pid} ->
        Logger.info("Poller registered: partition=#{partition_id} domain=#{domain} node=#{Node.self()}")
        schedule_heartbeat()
        {:ok, state}

      {:error, reason} ->
        Logger.error("Failed to register poller: #{inspect(reason)}")
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
    Logger.info("Poller status changed: #{state.status} -> #{new_status}")

    new_state = %{state | status: new_status}
    update_status(new_state)

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call(:get_info, _from, state) do
    info = %{
      partition_id: state.partition_id,
      domain: state.domain,
      capabilities: state.capabilities,
      node: Node.self(),
      status: state.status,
      registered_at: state.registered_at
    }

    {:reply, info, state}
  end

  @impl true
  def terminate(_reason, state) do
    Logger.info("Poller unregistering: #{inspect(state.key)}")
    ServiceRadar.PollerRegistry.unregister(state.key)

    Phoenix.PubSub.broadcast(
      ServiceRadarWebNG.PubSub,
      "poller:registrations",
      {:poller_unregistered, state.key}
    )

    :ok
  end

  # Public API

  @doc """
  Get the current poller status.
  """
  @spec get_status() :: atom()
  def get_status do
    GenServer.call(__MODULE__, :get_status)
  end

  @doc """
  Set the poller status.

  ## Examples

      ServiceRadar.Poller.RegistrationWorker.set_status(:unavailable)
      ServiceRadar.Poller.RegistrationWorker.set_status(:available)
  """
  @spec set_status(atom()) :: :ok
  def set_status(status) when status in [:available, :busy, :unavailable, :draining] do
    GenServer.call(__MODULE__, {:set_status, status})
  end

  @doc """
  Get poller information.
  """
  @spec get_info() :: map()
  def get_info do
    GenServer.call(__MODULE__, :get_info)
  end

  @doc """
  Mark poller as unavailable (for admin control).
  """
  @spec mark_unavailable() :: :ok
  def mark_unavailable do
    set_status(:unavailable)
  end

  @doc """
  Mark poller as available.
  """
  @spec mark_available() :: :ok
  def mark_available do
    set_status(:available)
  end

  # Private functions

  defp register_poller(state) do
    metadata = %{
      partition_id: state.partition_id,
      domain: state.domain,
      capabilities: state.capabilities,
      node: Node.self(),
      status: state.status,
      registered_at: state.registered_at,
      last_heartbeat: DateTime.utc_now()
    }

    case ServiceRadar.PollerRegistry.register(state.key, metadata) do
      {:ok, pid} ->
        # Broadcast registration
        Phoenix.PubSub.broadcast(
          ServiceRadarWebNG.PubSub,
          "poller:registrations",
          {:poller_registered, metadata}
        )

        {:ok, pid}

      error ->
        error
    end
  end

  defp update_heartbeat(state) do
    ServiceRadar.PollerRegistry.update_value(state.key, fn meta ->
      %{meta | last_heartbeat: DateTime.utc_now()}
    end)
  end

  defp update_status(state) do
    ServiceRadar.PollerRegistry.update_value(state.key, fn meta ->
      %{meta | status: state.status, last_heartbeat: DateTime.utc_now()}
    end)

    Phoenix.PubSub.broadcast(
      ServiceRadarWebNG.PubSub,
      "poller:registrations",
      {:poller_status_changed, state.key, state.status}
    )
  end

  defp schedule_heartbeat do
    Process.send_after(self(), :heartbeat, @heartbeat_interval)
  end

  @doc """
  Check if a poller is stale (no heartbeat for threshold period).
  """
  @spec stale?(map()) :: boolean()
  def stale?(poller_metadata) do
    case poller_metadata[:last_heartbeat] do
      nil ->
        true

      last_heartbeat ->
        diff = DateTime.diff(DateTime.utc_now(), last_heartbeat, :millisecond)
        diff > @stale_threshold
    end
  end
end
