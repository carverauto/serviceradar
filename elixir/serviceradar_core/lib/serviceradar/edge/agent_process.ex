defmodule ServiceRadar.Edge.AgentProcess do
  @moduledoc """
  GenServer representing an agent in the ERTS cluster.

  The AgentProcess is responsible for:
  1. Registering with the AgentRegistry for discoverability
  2. Maintaining a gRPC connection to the serviceradar-sync service
  3. Executing check requests from Pollers
  4. Collecting results FROM the sync service and returning them to Pollers

  ## Communication Pattern

  Core (AshOban) -> Poller -> Agent -> serviceradar-sync
                                   <-  (results)
  Core <- Poller <- Agent

  The AgentProcess receives work requests from Pollers and calls the sync
  service via gRPC to collect data. Results are returned to the Poller,
  which aggregates them and returns to Core for processing.

  Results can be returned synchronously or stored for async pickup via PubSub.

  ## Starting an Agent

      {:ok, pid} = ServiceRadar.Edge.AgentProcess.start_link(
        agent_id: "agent-uuid",
        tenant_id: "tenant-uuid",
        partition_id: "partition-1",
        capabilities: [:icmp_sweep, :tcp_sweep]
      )

  ## Configuration

  The sync service endpoint is configured via application config:

      config :serviceradar_core, ServiceRadar.Sync.Client,
        host: "sync.serviceradar.local",
        port: 50051
  """

  use GenServer

  require Logger

  alias ServiceRadar.AgentRegistry
  alias ServiceRadar.Sync.Client, as: SyncClient

  @type state :: %{
          agent_id: String.t(),
          tenant_id: String.t(),
          partition_id: String.t(),
          capabilities: [atom()],
          channel: GRPC.Channel.t() | nil,
          connected: boolean(),
          pending_requests: map()
        }

  @reconnect_interval 5_000
  @health_check_interval 30_000

  # Client API

  @doc """
  Start an agent process.
  """
  def start_link(opts) do
    agent_id = Keyword.fetch!(opts, :agent_id)
    GenServer.start_link(__MODULE__, opts, name: via_tuple(agent_id))
  end

  @doc """
  Execute a status check via this agent.

  The agent will forward the request to the sync service.
  """
  @spec execute_check(String.t() | pid(), map()) :: {:ok, map()} | {:error, term()}
  def execute_check(agent, request) when is_binary(agent) do
    case lookup_pid(agent) do
      nil -> {:error, :agent_not_found}
      pid -> execute_check(pid, request)
    end
  end

  def execute_check(agent, request) when is_pid(agent) do
    GenServer.call(agent, {:execute_check, request}, 60_000)
  end

  @doc """
  Execute a check asynchronously and store result for later pickup.

  Returns a request_id that can be used to retrieve results.
  """
  @spec execute_check_async(String.t() | pid(), map()) :: {:ok, String.t()} | {:error, term()}
  def execute_check_async(agent, request) when is_binary(agent) do
    case lookup_pid(agent) do
      nil -> {:error, :agent_not_found}
      pid -> execute_check_async(pid, request)
    end
  end

  def execute_check_async(agent, request) when is_pid(agent) do
    GenServer.call(agent, {:execute_check_async, request})
  end

  @doc """
  Report poller status to the sync service.
  """
  @spec report_status(String.t() | pid(), [Monitoring.ServiceStatus.t()], map()) ::
          {:ok, Monitoring.PollerStatusResponse.t()} | {:error, term()}
  def report_status(agent, services, opts) when is_binary(agent) do
    case lookup_pid(agent) do
      nil -> {:error, :agent_not_found}
      pid -> report_status(pid, services, opts)
    end
  end

  def report_status(agent, services, opts) when is_pid(agent) do
    GenServer.call(agent, {:report_status, services, opts}, 30_000)
  end

  @doc """
  Get the current status of this agent.
  """
  @spec status(String.t() | pid()) :: {:ok, map()} | {:error, term()}
  def status(agent) when is_binary(agent) do
    case lookup_pid(agent) do
      nil -> {:error, :agent_not_found}
      pid -> status(pid)
    end
  end

  def status(agent) when is_pid(agent) do
    GenServer.call(agent, :status)
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    agent_id = Keyword.fetch!(opts, :agent_id)
    tenant_id = Keyword.fetch!(opts, :tenant_id)
    partition_id = Keyword.get(opts, :partition_id, "default")
    capabilities = Keyword.get(opts, :capabilities, [])

    state = %{
      agent_id: agent_id,
      tenant_id: tenant_id,
      partition_id: partition_id,
      capabilities: capabilities,
      channel: nil,
      connected: false,
      pending_requests: %{}
    }

    # Register with the registry
    register_agent(state)

    # Connect to sync service
    send(self(), :connect)

    # Schedule health checks
    schedule_health_check()

    Logger.info("Agent #{agent_id} started for tenant #{tenant_id}/#{partition_id}")

    {:ok, state}
  end

  @impl true
  def handle_call({:execute_check, _request}, _from, %{connected: false} = state) do
    {:reply, {:error, :not_connected}, state}
  end

  def handle_call({:execute_check, request}, _from, state) do
    result = execute_check_impl(state.channel, request, state)
    {:reply, result, state}
  end

  def handle_call({:execute_check_async, _request}, _from, %{connected: false} = state) do
    {:reply, {:error, :not_connected}, state}
  end

  def handle_call({:execute_check_async, request}, from, state) do
    request_id = generate_request_id()

    # Spawn async execution
    parent = self()

    spawn(fn ->
      result = execute_check_impl(state.channel, request, state)
      GenServer.cast(parent, {:async_result, request_id, result})
    end)

    # Track pending request
    pending =
      Map.put(state.pending_requests, request_id, %{
        from: from,
        started_at: DateTime.utc_now()
      })

    {:reply, {:ok, request_id}, %{state | pending_requests: pending}}
  end

  def handle_call({:report_status, _services, _opts}, _from, %{connected: false} = state) do
    {:reply, {:error, :not_connected}, state}
  end

  def handle_call({:report_status, services, opts}, _from, state) do
    request = %Monitoring.PollerStatusRequest{
      services: services,
      poller_id: opts[:poller_id] || "",
      agent_id: state.agent_id,
      timestamp: System.system_time(:second),
      partition: state.partition_id,
      source_ip: opts[:source_ip] || "",
      kv_store_id: opts[:kv_store_id] || ""
    }

    result = SyncClient.report_status(state.channel, request)
    {:reply, result, state}
  end

  def handle_call(:status, _from, state) do
    status = %{
      agent_id: state.agent_id,
      tenant_id: state.tenant_id,
      partition_id: state.partition_id,
      capabilities: state.capabilities,
      connected: state.connected,
      pending_requests: map_size(state.pending_requests)
    }

    {:reply, {:ok, status}, state}
  end

  @impl true
  def handle_cast({:async_result, request_id, result}, state) do
    case Map.pop(state.pending_requests, request_id) do
      {nil, _} ->
        Logger.warning("Received result for unknown request #{request_id}")
        {:noreply, state}

      {%{from: _from} = _request_info, new_pending} ->
        # Broadcast result via PubSub
        Phoenix.PubSub.broadcast(
          ServiceRadar.PubSub,
          "agent:results:#{state.agent_id}",
          {:check_result, request_id, result}
        )

        {:noreply, %{state | pending_requests: new_pending}}
    end
  end

  @impl true
  def handle_info(:connect, state) do
    case SyncClient.connect() do
      {:ok, channel} ->
        Logger.info("Agent #{state.agent_id} connected to sync service")
        update_registry_status(state, :connected)
        {:noreply, %{state | channel: channel, connected: true}}

      {:error, reason} ->
        Logger.warning("Agent #{state.agent_id} failed to connect: #{inspect(reason)}")
        schedule_reconnect()
        {:noreply, state}
    end
  end

  def handle_info(:reconnect, state) do
    # Disconnect existing channel if any
    if state.channel do
      SyncClient.disconnect(state.channel)
    end

    send(self(), :connect)
    {:noreply, %{state | channel: nil, connected: false}}
  end

  def handle_info(:health_check, state) do
    if state.connected do
      # Update registry heartbeat
      AgentRegistry.heartbeat(state.agent_id)
    end

    schedule_health_check()
    {:noreply, state}
  end

  @impl true
  def terminate(reason, state) do
    Logger.info("Agent #{state.agent_id} terminating: #{inspect(reason)}")

    # Disconnect from sync
    if state.channel do
      SyncClient.disconnect(state.channel)
    end

    # Unregister from registry
    AgentRegistry.unregister_agent(state.agent_id)

    :ok
  end

  # Private Functions

  defp via_tuple(agent_id) do
    {:via, Registry, {ServiceRadar.LocalRegistry, {:agent, agent_id}}}
  end

  defp lookup_pid(agent_id) do
    case Registry.lookup(ServiceRadar.LocalRegistry, {:agent, agent_id}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  defp register_agent(state) do
    agent_info = %{
      tenant_id: state.tenant_id,
      partition_id: state.partition_id,
      capabilities: state.capabilities,
      # TODO: Get from SPIFFE workload API
      spiffe_id: nil
    }

    AgentRegistry.register_agent(state.agent_id, agent_info)
  end

  defp update_registry_status(state, status) do
    AgentRegistry.update_value(state.agent_id, fn meta ->
      Map.put(meta, :status, status)
    end)
  end

  defp execute_check_impl(channel, request, state) do
    # Build the gRPC request
    status_request = %Monitoring.StatusRequest{
      service_name: request[:service_name] || "",
      service_type: request[:service_type] || "",
      agent_id: state.agent_id,
      poller_id: request[:poller_id] || "",
      details: request[:details] || "",
      port: request[:port] || 0
    }

    # Call the sync service
    case Monitoring.AgentService.Stub.get_status(channel, status_request, timeout: 30_000) do
      {:ok, response} ->
        {:ok,
         %{
           available: response.available,
           message: response.message,
           service_name: response.service_name,
           service_type: response.service_type,
           response_time: response.response_time,
           agent_id: response.agent_id,
           poller_id: response.poller_id
         }}

      {:error, %GRPC.RPCError{} = error} ->
        Logger.error("gRPC error executing check: #{GRPC.RPCError.message(error)}")
        {:error, error}

      {:error, reason} ->
        Logger.error("Error executing check: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp schedule_reconnect do
    Process.send_after(self(), :reconnect, @reconnect_interval)
  end

  defp schedule_health_check do
    Process.send_after(self(), :health_check, @health_check_interval)
  end

  defp generate_request_id do
    :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
  end
end
