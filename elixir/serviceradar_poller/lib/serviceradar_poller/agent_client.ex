defmodule ServiceRadarPoller.AgentClient do
  @moduledoc """
  gRPC client for communicating with Go-based monitoring agents.

  ## Architecture

  Pollers initiate all connections to agents (agents never connect back).
  This ensures:
  - Minimal firewall exposure: only gRPC port open inbound to agent
  - No ERTS distribution in customer networks
  - Secure communication via mTLS

  ## Connection Management

  The client maintains a connection pool per agent. Connections are:
  - Established on first request
  - Kept alive via periodic health checks
  - Reconnected automatically on failure

  ## Usage

      # Get agent status (health check)
      {:ok, status} = AgentClient.get_status(tenant_id, agent_id)

      # Get sweep results from agent
      {:ok, results} = AgentClient.get_results(tenant_id, agent_id, %{
        service_type: "icmp_sweep",
        last_sequence: "seq-001"
      })

      # Stream results for large datasets
      AgentClient.stream_results(tenant_id, agent_id, opts, fn chunk ->
        process_chunk(chunk)
      end)
  """

  use GenServer

  require Logger

  alias ServiceRadar.AgentRegistry

  @connection_timeout :timer.seconds(10)
  @call_timeout :timer.seconds(30)
  @health_check_interval :timer.seconds(30)
  @reconnect_backoff_ms 1000

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Get status from an agent (health check).

  Returns `{:ok, status}` or `{:error, reason}`.
  """
  @spec get_status(String.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def get_status(tenant_id, agent_id, opts \\ %{}) do
    GenServer.call(__MODULE__, {:get_status, tenant_id, agent_id, opts}, @call_timeout)
  end

  @doc """
  Get results from an agent for a specific service.

  ## Options

    - `:service_type` - Type of service (e.g., "icmp_sweep", "snmp")
    - `:service_name` - Specific service name
    - `:last_sequence` - For incremental fetches
  """
  @spec get_results(String.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def get_results(tenant_id, agent_id, opts \\ %{}) do
    GenServer.call(__MODULE__, {:get_results, tenant_id, agent_id, opts}, @call_timeout)
  end

  @doc """
  Stream results from an agent.

  Calls the callback function for each chunk received.
  """
  @spec stream_results(String.t(), String.t(), map(), (map() -> any())) ::
          :ok | {:error, term()}
  def stream_results(tenant_id, agent_id, opts, callback) when is_function(callback, 1) do
    GenServer.call(__MODULE__, {:stream_results, tenant_id, agent_id, opts, callback}, @call_timeout)
  end

  @doc """
  Check if an agent is reachable.
  """
  @spec agent_reachable?(String.t(), String.t()) :: boolean()
  def agent_reachable?(tenant_id, agent_id) do
    case get_status(tenant_id, agent_id, %{}) do
      {:ok, %{available: true}} -> true
      _ -> false
    end
  end

  @doc """
  Get connection statistics.
  """
  @spec stats() :: map()
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    state = %{
      connections: %{},
      stats: %{
        calls: 0,
        errors: 0,
        reconnects: 0,
        started_at: DateTime.utc_now()
      }
    }

    # Schedule periodic health checks
    schedule_health_check()

    {:ok, state}
  end

  @impl true
  def handle_call({:get_status, tenant_id, agent_id, opts}, _from, state) do
    {result, new_state} = with_connection(state, tenant_id, agent_id, fn channel ->
      request = %Monitoring.StatusRequest{
        agent_id: agent_id,
        service_type: opts[:service_type] || "",
        service_name: opts[:service_name] || ""
      }

      case Monitoring.AgentService.Stub.get_status(channel, request, timeout: @call_timeout) do
        {:ok, response} ->
          {:ok, %{
            available: response.available,
            message: response.message,
            service_name: response.service_name,
            service_type: response.service_type,
            response_time: response.response_time
          }}

        {:error, reason} ->
          {:error, reason}
      end
    end)

    {:reply, result, new_state}
  end

  @impl true
  def handle_call({:get_results, tenant_id, agent_id, opts}, _from, state) do
    {result, new_state} = with_connection(state, tenant_id, agent_id, fn channel ->
      request = %Monitoring.ResultsRequest{
        agent_id: agent_id,
        service_type: opts[:service_type] || "",
        service_name: opts[:service_name] || "",
        last_sequence: opts[:last_sequence] || ""
      }

      case Monitoring.AgentService.Stub.get_results(channel, request, timeout: @call_timeout) do
        {:ok, response} ->
          {:ok, %{
            available: response.available,
            data: response.data,
            service_name: response.service_name,
            service_type: response.service_type,
            response_time: response.response_time,
            timestamp: response.timestamp,
            current_sequence: response.current_sequence,
            has_new_data: response.has_new_data
          }}

        {:error, reason} ->
          {:error, reason}
      end
    end)

    {:reply, result, new_state}
  end

  @impl true
  def handle_call({:stream_results, tenant_id, agent_id, opts, callback}, _from, state) do
    {result, new_state} = with_connection(state, tenant_id, agent_id, fn channel ->
      request = %Monitoring.ResultsRequest{
        agent_id: agent_id,
        service_type: opts[:service_type] || "",
        service_name: opts[:service_name] || "",
        last_sequence: opts[:last_sequence] || ""
      }

      case Monitoring.AgentService.Stub.stream_results(channel, request, timeout: @call_timeout) do
        {:ok, stream} ->
          Enum.each(stream, fn
            {:ok, chunk} ->
              callback.(%{
                data: chunk.data,
                is_final: chunk.is_final,
                chunk_index: chunk.chunk_index,
                total_chunks: chunk.total_chunks,
                current_sequence: chunk.current_sequence,
                timestamp: chunk.timestamp
              })

            {:error, reason} ->
              Logger.warning("Stream error from agent #{agent_id}: #{inspect(reason)}")
          end)

          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end)

    {:reply, result, new_state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats = Map.merge(state.stats, %{
      active_connections: map_size(state.connections),
      uptime_seconds: DateTime.diff(DateTime.utc_now(), state.stats.started_at)
    })

    {:reply, stats, state}
  end

  @impl true
  def handle_info(:health_check, state) do
    new_state = perform_health_checks(state)
    schedule_health_check()
    {:noreply, new_state}
  end

  @impl true
  def handle_info({:reconnect, key}, state) do
    Logger.info("Attempting reconnect to #{key}")
    # Connection will be re-established on next request
    new_connections = Map.delete(state.connections, key)
    {:noreply, %{state | connections: new_connections}}
  end

  # Private functions

  defp with_connection(state, tenant_id, agent_id, fun) do
    key = {tenant_id, agent_id}

    case get_or_create_connection(state, tenant_id, agent_id) do
      {:ok, channel, new_state} ->
        result = fun.(channel)

        new_state = update_stats(new_state, result)

        case result do
          {:error, %GRPC.RPCError{status: status}} when status in [:unavailable, :deadline_exceeded] ->
            # Connection issue, mark for reconnection
            Logger.warning("Connection issue with agent #{agent_id}, scheduling reconnect")
            new_connections = Map.delete(new_state.connections, key)
            schedule_reconnect(key)
            {result, %{new_state | connections: new_connections}}

          _ ->
            {result, new_state}
        end

      {:error, reason} ->
        {{:error, reason}, update_stats(state, {:error, reason})}
    end
  end

  defp get_or_create_connection(state, tenant_id, agent_id) do
    key = {tenant_id, agent_id}

    case Map.get(state.connections, key) do
      %{channel: channel, connected_at: _} ->
        {:ok, channel, state}

      nil ->
        case create_connection(tenant_id, agent_id) do
          {:ok, channel} ->
            conn_info = %{
              channel: channel,
              connected_at: DateTime.utc_now(),
              last_used: DateTime.utc_now()
            }

            new_connections = Map.put(state.connections, key, conn_info)
            {:ok, channel, %{state | connections: new_connections}}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp create_connection(tenant_id, agent_id) do
    case AgentRegistry.get_grpc_address(tenant_id, agent_id) do
      {:ok, {host, port}} ->
        Logger.info("Connecting to agent #{agent_id} at #{host}:#{port}")

        # TODO: Add mTLS options from SPIFFE certs
        case GRPC.Stub.connect("#{host}:#{port}", timeout: @connection_timeout) do
          {:ok, channel} ->
            Logger.info("Connected to agent #{agent_id}")
            {:ok, channel}

          {:error, reason} ->
            Logger.error("Failed to connect to agent #{agent_id}: #{inspect(reason)}")
            {:error, {:connection_failed, reason}}
        end

      {:error, :not_found} ->
        {:error, :agent_not_registered}

      {:error, :no_grpc_address} ->
        {:error, :no_grpc_address}
    end
  end

  defp perform_health_checks(state) do
    Enum.reduce(state.connections, state, fn {{tenant_id, agent_id}, conn_info}, acc ->
      request = %Monitoring.StatusRequest{agent_id: agent_id}

      case Monitoring.AgentService.Stub.get_status(conn_info.channel, request, timeout: 5000) do
        {:ok, _response} ->
          # Update last_used timestamp
          new_conn = Map.put(conn_info, :last_used, DateTime.utc_now())
          new_connections = Map.put(acc.connections, {tenant_id, agent_id}, new_conn)
          %{acc | connections: new_connections}

        {:error, _reason} ->
          Logger.warning("Health check failed for agent #{agent_id}")
          new_connections = Map.delete(acc.connections, {tenant_id, agent_id})
          schedule_reconnect({tenant_id, agent_id})
          %{acc | connections: new_connections}
      end
    end)
  end

  defp schedule_health_check do
    Process.send_after(self(), :health_check, @health_check_interval)
  end

  defp schedule_reconnect(key, delay \\ @reconnect_backoff_ms) do
    Process.send_after(self(), {:reconnect, key}, delay)
  end

  defp update_stats(state, result) do
    stats = state.stats

    new_stats =
      case result do
        {:ok, _} ->
          %{stats | calls: stats.calls + 1}

        {:error, _} ->
          %{stats | calls: stats.calls + 1, errors: stats.errors + 1}

        :ok ->
          %{stats | calls: stats.calls + 1}
      end

    %{state | stats: new_stats}
  end
end
