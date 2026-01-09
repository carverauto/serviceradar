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
      - `:tenant_id` - Tenant UUID for multi-tenant routing
      - `:tenant_slug` - Tenant slug for NATS subject prefixing

  ## Returns

    - `:ok` on success
    - `{:error, reason}` on failure
  """
  @spec process(map()) :: :ok | {:error, term()}
  def process(status) do
    with :ok <- validate_status(status),
         status <- normalize_status(status),
         :ok <- forward_to_core(status) do
      # Track this agent for UI visibility
      track_agent(status)
      :ok
    end
  end

  # Track the agent that sent this status update
  defp track_agent(status) do
    agent_id = status[:agent_id]
    tenant_slug = status[:tenant_slug] || "default"

    metadata = %{
      service_count: 1,
      partition: status[:partition],
      source_ip: status[:source_ip]
    }

    ServiceRadar.AgentTracker.track_agent(agent_id, tenant_slug, metadata)
  rescue
    # AgentTracker may not be available (e.g., during tests)
    _ -> :ok
  end

  # Validate required fields in the status
  defp validate_status(status) do
    required_fields = [:service_name, :service_type, :agent_id]

    missing =
      required_fields
      |> Enum.filter(fn field ->
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
    _tenant_id = status[:tenant_id]
    tenant_slug = status[:tenant_slug]

    Logger.debug(
      "Forwarding status to core: tenant=#{tenant_slug} partition=#{partition} agent=#{agent_id} service=#{service_name}"
    )

    # Try to forward to the core cluster
    # First check if we have a local core process, then try distributed
    case forward_local(status) do
      :ok ->
        :ok

      {:error, :not_available} ->
        forward_distributed(status)

      error ->
        error
    end
  end

  # Forward to local core process (same node)
  defp forward_local(status) do
    # Check if core is available locally
    case Process.whereis(ServiceRadar.StatusHandler) do
      nil ->
        {:error, :not_available}

      pid when is_pid(pid) ->
        try do
          GenServer.cast(pid, {:status_update, status})
          :ok
        catch
          :exit, _ -> {:error, :not_available}
        end
    end
  end

  # Forward to distributed core process via RPC
  defp forward_distributed(status) do
    tenant_slug = status[:tenant_slug] || "default"

    case find_status_handler_node() do
      {:ok, node} ->
        try do
          # Cast to StatusHandler on the remote node
          GenServer.cast({ServiceRadar.StatusHandler, node}, {:status_update, status})
          Logger.debug("Forwarded status to StatusHandler on #{node} for tenant=#{tenant_slug}")
          :ok
        catch
          :exit, reason ->
            Logger.warning("Failed to forward status to core on #{node}: #{inspect(reason)}")
            {:error, :forward_failed}
        end

      {:error, :not_found} ->
        Logger.debug("No StatusHandler found on any node, queuing for retry")
        queue_for_retry(status)
    end
  end

  # Find a node that has StatusHandler running
  defp find_status_handler_node do
    nodes = [Node.self() | Node.list()] |> Enum.uniq()

    # First, try to find nodes with StatusHandler
    handler_nodes =
      Enum.filter(nodes, fn node ->
        case :rpc.call(node, Process, :whereis, [ServiceRadar.StatusHandler], 5_000) do
          pid when is_pid(pid) -> true
          _ -> false
        end
      end)

    case handler_nodes do
      [node | _] -> {:ok, node}
      [] -> {:error, :not_found}
    end
  end

  # Queue status for retry when core is not available
  defp queue_for_retry(_status) do
    # For now, just log and return ok
    # In a full implementation, this would use a persistent queue
    # or retry with backoff
    :ok
  end
end
