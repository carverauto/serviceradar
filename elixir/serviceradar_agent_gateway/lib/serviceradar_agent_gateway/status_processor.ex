defmodule ServiceRadarAgentGateway.StatusProcessor do
  @moduledoc """
  Processes service status updates received from agents.

  This module is the integration point between the agent gateway and the
  ServiceRadar core. It handles:

  1. Validation of incoming status data
  2. Normalization of status formats
  3. Forwarding to the appropriate core handlers
  4. Recording of telemetry/metrics

  ## Integration with Core

  Status updates are forwarded to the distributed core cluster via:
  - Direct GenServer calls for local processing
  - Distributed routing for partition-aware processing
  """

  alias ServiceRadarAgentGateway.StatusBuffer

  require Logger

  @doc """
  Process a service status update.

  Takes a status map and forwards it to the appropriate handler
  in the core cluster.

  ## Parameters

    - `status`: A map containing:
      - `:service_name` - Name of the service
      - `:available` - Boolean availability status
      - `:message` - Status message (binary)
      - `:service_type` - Type of service (e.g., "sweep", "process")
      - `:response_time` - Response time in nanoseconds
      - `:agent_id` - ID of the reporting agent
      - `:gateway_id` - ID of the gateway
      - `:partition` - Partition identifier
      - `:source` - Source type ("status" or "results")
      - `:kv_store_id` - KV store identifier
      - `:timestamp` - Unix timestamp in nanoseconds

  ## Returns

    - `:ok` on success
    - `{:error, reason}` on failure
  """
  @spec process(map()) :: :ok | {:error, term()}
  def process(status) do
    with :ok <- validate_status(status),
         status = normalize_status(status),
         :ok <- forward(status) do
      # Track this agent for UI visibility
      track_agent(status)
      :ok
    end
  end

  @spec forward(map(), keyword()) :: :ok | {:error, term()}
  def forward(status, opts \\ []) do
    buffer_on_failure = Keyword.get(opts, :buffer_on_failure, true)
    from_buffer = Keyword.get(opts, :from_buffer, false)
    started_at = System.monotonic_time()

    case forward_to_core(status) do
      :ok ->
        emit_forward_metrics(:ok, status, from_buffer, started_at)
        :ok

      {:error, reason} ->
        if buffer_on_failure and should_buffer?(status) do
          enqueue_buffered_status(status)
          emit_forward_metrics(:buffered, status, from_buffer, started_at)
          :ok
        else
          emit_forward_metrics(:failed, status, from_buffer, started_at)
          {:error, reason}
        end
    end
  end

  defp enqueue_buffered_status(status) do
    case Process.whereis(StatusBuffer) do
      nil ->
        Logger.debug("Results buffer unavailable; dropping status")

      _pid ->
        StatusBuffer.enqueue(status)
    end
  end

  # Track the agent that sent this status update
  defp track_agent(status) do
    agent_id = status[:agent_id]

    metadata = %{
      service_count: 1,
      partition: status[:partition],
      source_ip: status[:source_ip]
    }

    ServiceRadar.AgentTracker.track_agent(agent_id, metadata)
  rescue
    # AgentTracker may not be available (e.g., during tests)
    _ -> :ok
  end

  # Validate required fields in the status
  defp validate_status(status) do
    required_fields = [:service_name, :service_type, :agent_id]

    missing =
      Enum.filter(required_fields, fn field ->
        value = Map.get(status, field)
        is_nil(value) or value == ""
      end)

    if Enum.empty?(missing) do
      :ok
    else
      {:error, {:missing_fields, missing}}
    end
  end

  # Normalize status data for consistent processing
  defp normalize_status(status) do
    status
    |> Map.put_new(:timestamp, System.system_time(:nanosecond))
    |> Map.put_new(:partition, "default")
    |> Map.update(:message, nil, &normalize_message/1)
  end

  # Ensure message is properly formatted
  defp normalize_message(nil), do: nil
  defp normalize_message(msg) when is_binary(msg), do: msg
  defp normalize_message(msg), do: inspect(msg)

  # Forward the status to the core cluster
  defp forward_to_core(status) do
    partition = status[:partition]
    agent_id = status[:agent_id]
    service_name = status[:service_name]
    handler = ServiceRadar.StatusHandler

    Logger.debug(
      "Forwarding status to core: partition=#{partition} " <>
        "agent=#{agent_id} service=#{service_name}"
    )

    # Try to forward to the core cluster
    # First check if we have a local core process, then try distributed
    case forward_local(status, handler) do
      :ok ->
        :ok

      {:error, :not_available} ->
        forward_distributed(status, handler)
    end
  end

  # Forward to local core process (same node)
  defp forward_local(status, handler) do
    # Check if core is available locally
    message = handler_message(status)

    case Process.whereis(handler) do
      nil ->
        {:error, :not_available}

      pid when is_pid(pid) ->
        try do
          GenServer.cast(pid, message)
          :ok
        catch
          :exit, _ -> {:error, :not_available}
        end
    end
  end

  # Forward to distributed core process via RPC
  defp forward_distributed(status, handler) do
    message = handler_message(status)

    case find_handler_node(handler) do
      {:ok, node} ->
        try do
          # Cast to the core handler on the remote node
          GenServer.cast({handler, node}, message)
          Logger.debug("Forwarded status to #{inspect(handler)} on #{node}")

          :ok
        catch
          :exit, reason ->
            Logger.warning("Failed to forward status to core on #{node}: #{inspect(reason)}")
            {:error, :forward_failed}
        end

      {:error, :not_found} ->
        Logger.debug("No handler found on any node")
        {:error, :not_available}
    end
  end

  defp handler_message(status), do: {:status_update, status}

  # Find a node that has the handler running
  defp find_handler_node(handler) do
    nodes = Enum.uniq([Node.self() | Node.list()])

    # First, try to find nodes with the handler
    handler_nodes =
      Enum.filter(nodes, fn node ->
        case :rpc.call(node, Process, :whereis, [handler], 5_000) do
          pid when is_pid(pid) -> true
          _ -> false
        end
      end)

    case handler_nodes do
      [node | _] -> {:ok, node}
      [] -> {:error, :not_found}
    end
  end

  defp should_buffer?(status), do: results_router_source?(status)

  defp results_router_source?(status) do
    status[:source] in [
      "results",
      :results,
      "sysmon-metrics",
      :sysmon_metrics,
      "plugin-result",
      :plugin_result
    ]
  end

  defp emit_forward_metrics(result, status, from_buffer, started_at) do
    if should_buffer?(status) do
      duration_ms =
        System.monotonic_time()
        |> Kernel.-(started_at)
        |> System.convert_time_unit(:native, :millisecond)

      :telemetry.execute(
        [:serviceradar, :agent_gateway, :results, :forward],
        %{count: 1, duration_ms: duration_ms},
        %{
          result: result,
          from_buffer: from_buffer,
          service_type: status[:service_type],
          service_name: status[:service_name],
          agent_id: status[:agent_id],
          gateway_id: status[:gateway_id],
          partition: status[:partition]
        }
      )
    end
  end
end
