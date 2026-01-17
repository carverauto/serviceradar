defmodule ServiceRadarAgentGateway.AgentClient do
  @moduledoc """
  gRPC client for communicating with Go-based monitoring agents (legacy support).

  This client is maintained for backwards compatibility with the old polling model
  where the gateway would poll agents. In the new architecture, agents push status
  to the gateway instead.

  ## Architecture

  In the legacy model:
  - Gateway initiates connections to agents (agents never connect back)
  - Minimal firewall exposure: only gRPC port open inbound to agent
  - Secure communication via mTLS

  In the new model:
  - Agents push status to the gateway (see AgentGatewayServer)
  - Gateway never needs to initiate connections
  - Simpler firewall rules: agents only need outbound access

  ## Connection Management

  The client maintains a connection pool per agent. Connections are:
  - Established on first request
  - Kept alive via periodic health checks
  - Reconnected automatically on failure
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
  @spec get_status(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def get_status(agent_id, opts \\ %{}) do
    GenServer.call(__MODULE__, {:get_status, agent_id, opts}, @call_timeout)
  end

  @doc """
  Get results from an agent for a specific service.

  ## Options

    - `:service_type` - Type of service (e.g., "icmp_sweep", "snmp")
    - `:service_name` - Specific service name
    - `:last_sequence` - For incremental fetches
  """
  @spec get_results(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def get_results(agent_id, opts \\ %{}) do
    GenServer.call(__MODULE__, {:get_results, agent_id, opts}, @call_timeout)
  end

  @doc """
  Stream results from an agent.

  Calls the callback function for each chunk received.
  """
  @spec stream_results(String.t(), map(), (map() -> any())) ::
          :ok | {:error, term()}
  def stream_results(agent_id, opts, callback) when is_function(callback, 1) do
    GenServer.call(__MODULE__, {:stream_results, agent_id, opts, callback}, @call_timeout)
  end

  @doc """
  Check if an agent is reachable.
  """
  @spec agent_reachable?(String.t()) :: boolean()
  def agent_reachable?(agent_id) do
    case get_status(agent_id, %{}) do
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
  def handle_call({:get_status, agent_id, opts}, _from, state) do
    {result, new_state} = with_connection(state, agent_id, fn channel ->
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
  def handle_call({:get_results, agent_id, opts}, _from, state) do
    {result, new_state} = with_connection(state, agent_id, fn channel ->
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
  def handle_call({:stream_results, agent_id, opts, callback}, _from, state) do
    {result, new_state} = with_connection(state, agent_id, fn channel ->
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
  def handle_info({:reconnect, agent_id}, state) do
    Logger.info("Attempting reconnect to agent #{agent_id}")
    # Connection will be re-established on next request
    new_connections = Map.delete(state.connections, agent_id)
    {:noreply, %{state | connections: new_connections}}
  end

  # Private functions

  defp with_connection(state, agent_id, fun) do
    case get_or_create_connection(state, agent_id) do
      {:ok, channel, new_state} ->
        result = fun.(channel)

        new_state = update_stats(new_state, result)

        case result do
          {:error, %GRPC.RPCError{status: status}} when status in [:unavailable, :deadline_exceeded] ->
            # Connection issue, mark for reconnection
            Logger.warning("Connection issue with agent #{agent_id}, scheduling reconnect")
            new_connections = Map.delete(new_state.connections, agent_id)
            schedule_reconnect(agent_id)
            {result, %{new_state | connections: new_connections}}

          _ ->
            {result, new_state}
        end

      {:error, reason} ->
        {{:error, reason}, update_stats(state, {:error, reason})}
    end
  end

  defp get_or_create_connection(state, agent_id) do
    case Map.get(state.connections, agent_id) do
      %{channel: channel, connected_at: _} ->
        {:ok, channel, state}

      nil ->
        case create_connection(agent_id) do
          {:ok, channel} ->
            conn_info = %{
              channel: channel,
              connected_at: DateTime.utc_now(),
              last_used: DateTime.utc_now()
            }

            new_connections = Map.put(state.connections, agent_id, conn_info)
            {:ok, channel, %{state | connections: new_connections}}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp create_connection(agent_id) do
    case AgentRegistry.get_grpc_address(agent_id) do
      {:ok, {host, port}} ->
        Logger.info("Connecting to agent #{agent_id} at #{host}:#{port}")

        cred_opts = build_grpc_credentials(host)
        connect_opts = [timeout: @connection_timeout] ++ cred_opts

        case GRPC.Stub.connect("#{host}:#{port}", connect_opts) do
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

  # Build gRPC credentials with mTLS if configured
  defp build_grpc_credentials(host) do
    case gateway_client_ssl_opts() do
      {:ok, ssl_opts} ->
        ssl_opts_with_sni =
          ssl_opts
          |> Keyword.put(:server_name_indication, String.to_charlist(host))

        Logger.debug("Using mTLS for agent connection")
        [cred: GRPC.Credential.new(ssl: ssl_opts_with_sni)]

      {:error, reason} ->
        Logger.warning("mTLS not available (#{inspect(reason)}), using insecure connection")
        []
    end
  end

  defp gateway_client_ssl_opts do
    cert_dir = System.get_env("GATEWAY_CERT_DIR", "/etc/serviceradar/certs")
    cert_file = Path.join(cert_dir, "gateway.pem")
    key_file = Path.join(cert_dir, "gateway-key.pem")
    ca_file = Path.join(cert_dir, "root.pem")

    if File.exists?(cert_file) and File.exists?(key_file) and File.exists?(ca_file) do
      ssl_opts = [
        cacertfile: String.to_charlist(ca_file),
        certfile: String.to_charlist(cert_file),
        keyfile: String.to_charlist(key_file),
        verify: :verify_peer
      ]

      {:ok, ssl_opts}
    else
      {:error, :gateway_certs_missing}
    end
  end

  defp perform_health_checks(state) do
    Enum.reduce(state.connections, state, fn {agent_id, conn_info}, acc ->
      request = %Monitoring.StatusRequest{agent_id: agent_id}

      case Monitoring.AgentService.Stub.get_status(conn_info.channel, request, timeout: 5000) do
        {:ok, _response} ->
          # Update last_used timestamp
          new_conn = Map.put(conn_info, :last_used, DateTime.utc_now())
          new_connections = Map.put(acc.connections, agent_id, new_conn)
          %{acc | connections: new_connections}

        {:error, _reason} ->
          Logger.warning("Health check failed for agent #{agent_id}")
          new_connections = Map.delete(acc.connections, agent_id)
          schedule_reconnect(agent_id)
          %{acc | connections: new_connections}
      end
    end)
  end

  defp schedule_health_check do
    Process.send_after(self(), :health_check, @health_check_interval)
  end

  defp schedule_reconnect(agent_id, delay \\ @reconnect_backoff_ms) do
    Process.send_after(self(), {:reconnect, agent_id}, delay)
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
