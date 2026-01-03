defmodule ServiceRadarAgentGateway.AgentGatewayServer do
  @moduledoc """
  gRPC server that receives status pushes from Go agents.

  ## Architecture

  Agents initiate all connections to the gateway (gateway never connects back).
  This ensures:
  - Agents can connect outbound through firewalls
  - No inbound firewall rules needed in customer networks
  - Secure communication via mTLS

  ## Multi-Tenant Security

  Tenant identity is extracted from the mTLS client certificate using
  `ServiceRadar.Edge.TenantResolver`. The certificate contains:
  - CN: `<component_id>.<partition_id>.<tenant_slug>.serviceradar`
  - SPIFFE URI SAN: `spiffe://serviceradar.local/<component_type>/<tenant_slug>/<partition_id>/<component_id>`

  The issuer CA SPKI hash is also verified against stored tenant CA records.
  This ensures tenants cannot impersonate each other.

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

  alias ServiceRadar.Edge.TenantResolver
  alias ServiceRadarAgentGateway.StatusProcessor

  # Default tenant values when no mTLS cert is available
  @default_tenant_id "00000000-0000-0000-0000-000000000000"
  @default_tenant_slug "default"

  @doc """
  Handle a status push from an agent.

  Receives a batch of service statuses and forwards them to the core
  for processing and storage.
  """
  @spec push_status(Monitoring.GatewayStatusRequest.t(), GRPC.Server.Stream.t()) ::
          Monitoring.GatewayStatusResponse.t()
  def push_status(request, stream) do
    agent_id = request.agent_id
    service_count = length(request.services)

    # Extract tenant from mTLS certificate (secure source of truth)
    {tenant_id, tenant_slug} = extract_tenant_from_stream(stream)

    Logger.info(
      "Received status push from agent #{agent_id}: #{service_count} services (tenant: #{tenant_slug})"
    )

    # Extract metadata from request including tenant context
    metadata = %{
      agent_id: agent_id,
      gateway_id: request.gateway_id,
      partition: request.partition,
      source_ip: request.source_ip,
      kv_store_id: request.kv_store_id,
      timestamp: request.timestamp,
      tenant_id: tenant_id,
      tenant_slug: tenant_slug
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
  def stream_status(request_stream, stream) do
    Logger.debug("Starting streaming status reception")

    # Extract tenant from mTLS certificate once for all chunks
    {tenant_id, tenant_slug} = extract_tenant_from_stream(stream)

    total_services =
      Enum.reduce(request_stream, 0, fn chunk, acc ->
        agent_id = chunk.agent_id
        service_count = length(chunk.services)

        Logger.debug(
          "Received chunk #{chunk.chunk_index + 1}/#{chunk.total_chunks} from agent #{agent_id} (tenant: #{tenant_slug})"
        )

        # Extract metadata from chunk including tenant context from mTLS cert
        metadata = %{
          agent_id: agent_id,
          gateway_id: chunk.gateway_id,
          partition: chunk.partition,
          source_ip: chunk.source_ip,
          kv_store_id: chunk.kv_store_id,
          timestamp: chunk.timestamp,
          chunk_index: chunk.chunk_index,
          total_chunks: chunk.total_chunks,
          is_final: chunk.is_final,
          tenant_id: tenant_id,
          tenant_slug: tenant_slug
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
    # Tenant comes from mTLS cert via metadata, NOT from the service message
    # This is critical for security - prevents tenant spoofing
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
      timestamp: metadata.timestamp,
      tenant_id: metadata.tenant_id,
      tenant_slug: metadata.tenant_slug
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

  # Extract tenant info from the gRPC stream's mTLS certificate
  # Uses TenantResolver to properly validate and extract tenant identity
  defp extract_tenant_from_stream(stream) do
    case get_peer_cert(stream) do
      {:ok, cert_der} ->
        case TenantResolver.resolve_from_cert(cert_der) do
          {:ok, %{tenant_id: tenant_id, tenant_slug: tenant_slug}} when not is_nil(tenant_id) ->
            {tenant_id, tenant_slug}

          {:ok, %{tenant_slug: tenant_slug}} when not is_nil(tenant_slug) ->
            # tenant_id not available (no issuer lookup), use default
            {@default_tenant_id, tenant_slug}

          {:error, reason} ->
            Logger.debug("TenantResolver failed: #{inspect(reason)}, using default tenant")
            {@default_tenant_id, @default_tenant_slug}
        end

      {:error, reason} ->
        Logger.debug("Could not extract peer certificate: #{inspect(reason)}, using default tenant")
        {@default_tenant_id, @default_tenant_slug}
    end
  end

  # Get the peer certificate from the gRPC stream
  defp get_peer_cert(stream) do
    # The stream has an adapter with socket info
    # For mTLS, the peer certificate is in the SSL socket
    try do
      case stream.adapter do
        %{socket: socket} when is_port(socket) ->
          case :ssl.peercert(socket) do
            {:ok, cert_der} -> {:ok, cert_der}
            {:error, reason} -> {:error, reason}
          end

        _ ->
          {:error, :no_socket}
      end
    rescue
      _ -> {:error, :extraction_failed}
    catch
      _, _ -> {:error, :extraction_failed}
    end
  end
end
