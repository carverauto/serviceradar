defmodule ServiceRadarAgentGateway.AgentGatewayServer do
  @moduledoc """
  gRPC server that receives status pushes from Go agents.

  ## Architecture

  Agents initiate all connections to the gateway (gateway never connects back).
  This ensures:
  - Agents can connect outbound through firewalls
  - No inbound firewall rules needed in customer networks
  - Secure communication via mTLS

  ## Protocol

  The server implements the AgentGatewayService:
  - `PushStatus`: Receives a batch of service statuses from an agent
  - `StreamStatus`: Receives streaming chunks of service statuses

  ## Usage

  The server is started automatically by the application supervisor.
  Incoming status updates are forwarded to the core cluster for processing.
  """

  use GRPC.Server, service: Monitoring.AgentGatewayService.Service

  require Logger

  alias ServiceRadarAgentGateway.StatusProcessor

  @doc """
  Handle a status push from an agent.

  Receives a batch of service statuses and forwards them to the core
  for processing and storage.
  """
  @spec push_status(Monitoring.GatewayStatusRequest.t(), GRPC.Server.Stream.t()) ::
          Monitoring.GatewayStatusResponse.t()
  def push_status(request, _stream) do
    agent_id = request.agent_id
    service_count = length(request.services)

    Logger.info(
      "Received status push from agent #{agent_id}: #{service_count} services"
    )

    # Extract metadata from request
    metadata = %{
      agent_id: agent_id,
      gateway_id: request.gateway_id,
      partition: request.partition,
      source_ip: request.source_ip,
      kv_store_id: request.kv_store_id,
      timestamp: request.timestamp
    }

    # Process each service status
    Enum.each(request.services, fn service ->
      process_service_status(service, metadata)
    end)

    # Record metrics
    record_push_metrics(agent_id, service_count)

    %Monitoring.GatewayStatusResponse{received: true}
  end

  @doc """
  Handle streaming status updates from an agent.

  Receives chunked status updates for large payloads and forwards
  them to the core for processing.
  """
  @spec stream_status(Enumerable.t(), GRPC.Server.Stream.t()) ::
          Monitoring.GatewayStatusResponse.t()
  def stream_status(request_stream, _stream) do
    Logger.debug("Starting streaming status reception")

    total_services =
      Enum.reduce(request_stream, 0, fn chunk, acc ->
        agent_id = chunk.agent_id
        service_count = length(chunk.services)

        Logger.debug(
          "Received chunk #{chunk.chunk_index + 1}/#{chunk.total_chunks} from agent #{agent_id}"
        )

        # Extract metadata from chunk
        metadata = %{
          agent_id: agent_id,
          gateway_id: chunk.gateway_id,
          partition: chunk.partition,
          source_ip: chunk.source_ip,
          kv_store_id: chunk.kv_store_id,
          timestamp: chunk.timestamp,
          chunk_index: chunk.chunk_index,
          total_chunks: chunk.total_chunks,
          is_final: chunk.is_final
        }

        # Process each service status in the chunk
        Enum.each(chunk.services, fn service ->
          process_service_status(service, metadata)
        end)

        if chunk.is_final do
          record_push_metrics(agent_id, acc + service_count)
        end

        acc + service_count
      end)

    Logger.info("Completed streaming status reception: #{total_services} total services")

    %Monitoring.GatewayStatusResponse{received: true}
  end

  # Process a single service status and forward to the core
  defp process_service_status(service, metadata) do
    status = %{
      service_name: service.service_name,
      available: service.available,
      message: service.message,
      service_type: service.service_type,
      response_time: service.response_time,
      agent_id: service.agent_id || metadata.agent_id,
      gateway_id: service.gateway_id || metadata.gateway_id,
      partition: service.partition || metadata.partition,
      source: service.source,
      kv_store_id: service.kv_store_id || metadata.kv_store_id,
      timestamp: metadata.timestamp
    }

    # Forward to the status processor (delegates to core)
    case StatusProcessor.process(status) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Failed to process status for service #{service.service_name}: #{inspect(reason)}"
        )
    end
  end

  # Record metrics for the push operation
  defp record_push_metrics(agent_id, service_count) do
    # TODO: Integrate with telemetry/metrics system
    Logger.debug("Recorded push metrics: agent=#{agent_id} services=#{service_count}")
  end
end
