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

  # Default heartbeat interval for agents
  @default_heartbeat_interval_sec 30

  # Maximum services per push request to prevent resource exhaustion
  @max_services_per_request 5_000

  # Gateway identifier (node name or configured ID)
  defp gateway_id do
    node() |> Atom.to_string()
  end

  @doc """
  Handle an agent hello/enrollment request.

  Called by the agent on startup to announce itself and register with the gateway.
  Validates the mTLS certificate, extracts tenant identity, and registers the agent.
  """
  @spec hello(Monitoring.AgentHelloRequest.t(), GRPC.Server.Stream.t()) ::
          Monitoring.AgentHelloResponse.t()
  def hello(request, stream) do
    agent_id =
      case request.agent_id do
        nil ->
          ""

        value ->
          value
          |> to_string()
          |> String.trim()
      end

    if agent_id == "" do
      raise GRPC.RPCError, status: :invalid_argument, message: "agent_id is required"
    end

    version = request.version
    capabilities = request.capabilities || []

    Logger.info("Agent hello received: agent_id=#{agent_id}, version=#{version}")
    Logger.debug("Agent capabilities: #{inspect(capabilities)}")

    # Extract tenant from mTLS certificate (secure source of truth)
    {tenant_id, tenant_slug} = extract_tenant_from_stream(stream)

    # TODO: Register the agent with the core (AgentTracker)
    # For now, we accept all agents with valid certificates
    # In the future, this should verify the agent is expected for this tenant

    # Check if config is outdated (placeholder - always false for now)
    # TODO: Implement config versioning in core-elx
    config_outdated = request.config_version == "" or request.config_version == nil

    Logger.info(
      "Agent enrolled: agent_id=#{agent_id}, tenant=#{tenant_slug}, config_outdated=#{config_outdated}"
    )

    %Monitoring.AgentHelloResponse{
      accepted: true,
      agent_id: agent_id,
      message: "Agent enrolled successfully",
      gateway_id: gateway_id(),
      server_time: System.os_time(:second),
      heartbeat_interval_sec: @default_heartbeat_interval_sec,
      config_outdated: config_outdated,
      tenant_id: tenant_id,
      tenant_slug: tenant_slug
    }
  end

  @doc """
  Handle an agent config request.

  Returns the agent's configuration from the SaaS control plane.
  Supports versioning - returns not_modified if config hasn't changed.

  The configuration is loaded from CNPG based on the agent's assigned
  service checks. A SHA256 hash of the config is used for versioning,
  so agents can cache their config and only fetch updates when changed.
  """
  @spec get_config(Monitoring.AgentConfigRequest.t(), GRPC.Server.Stream.t()) ::
          Monitoring.AgentConfigResponse.t()
  def get_config(request, stream) do
    agent_id =
      case request.agent_id do
        nil ->
          ""

        value ->
          value
          |> to_string()
          |> String.trim()
      end

    if agent_id == "" do
      raise GRPC.RPCError, status: :invalid_argument, message: "agent_id is required"
    end

    config_version = request.config_version || ""

    Logger.debug("Agent config request: agent_id=#{agent_id}, version=#{config_version}")

    # Extract tenant from mTLS certificate for authorization
    {tenant_id, tenant_slug} = extract_tenant_from_stream(stream)

    # Generate config from database using the config generator
    case ServiceRadar.Edge.AgentConfigGenerator.get_config_if_changed(
           agent_id,
           tenant_id,
           config_version
         ) do
      :not_modified ->
        Logger.debug("Agent config not modified: agent_id=#{agent_id}, version=#{config_version}")

        %Monitoring.AgentConfigResponse{
          not_modified: true,
          config_version: config_version
        }

      {:ok, config} ->
        Logger.info(
          "Sending config to agent: agent_id=#{agent_id}, tenant=#{tenant_slug}, version=#{config.config_version}, checks=#{length(config.checks)}"
        )

        # Convert checks to proto format
        proto_checks = ServiceRadar.Edge.AgentConfigGenerator.to_proto_checks(config.checks)

        %Monitoring.AgentConfigResponse{
          not_modified: false,
          config_version: config.config_version,
          config_timestamp: config.config_timestamp,
          heartbeat_interval_sec: config.heartbeat_interval_sec,
          config_poll_interval_sec: config.config_poll_interval_sec,
          checks: proto_checks
        }

      {:error, reason} ->
        Logger.warning(
          "Failed to generate config for agent #{agent_id}: #{inspect(reason)}, returning empty config"
        )

        # Return empty config on error rather than failing the request
        %Monitoring.AgentConfigResponse{
          not_modified: false,
          config_version: "v0-error",
          config_timestamp: System.os_time(:second),
          heartbeat_interval_sec: @default_heartbeat_interval_sec,
          config_poll_interval_sec: 300,
          checks: []
        }
    end
  end

  @doc """
  Handle a status push from an agent.

  Receives a batch of service statuses and forwards them to the core
  for processing and storage.
  """
  @spec push_status(Monitoring.GatewayStatusRequest.t(), GRPC.Server.Stream.t()) ::
          Monitoring.GatewayStatusResponse.t()
  def push_status(request, stream) do
    agent_id =
      case request.agent_id do
        nil ->
          ""

        value ->
          value
          |> to_string()
          |> String.trim()
      end

    if agent_id == "" do
      raise GRPC.RPCError, status: :invalid_argument, message: "agent_id is required"
    end

    services = request.services || []
    service_count = length(services)

    if service_count > @max_services_per_request do
      raise GRPC.RPCError,
        status: :resource_exhausted,
        message: "too many service statuses in one request (max: #{@max_services_per_request})"
    end

    # Extract tenant from mTLS certificate (secure source of truth)
    {tenant_id, tenant_slug} = extract_tenant_from_stream(stream)
    partition = normalize_partition(request.partition)

    Logger.info(
      "Received status push from agent #{agent_id}: #{service_count} services (tenant: #{tenant_slug})"
    )

    # Extract metadata from request including tenant context
    # Use server's gateway_id() instead of client-provided request.gateway_id
    # to prevent spoofing and ensure correct data attribution
    metadata = %{
      agent_id: agent_id,
      gateway_id: gateway_id(),
      partition: partition,
      source_ip: get_peer_ip(stream),
      kv_store_id: request.kv_store_id,
      timestamp: System.os_time(:second),
      agent_timestamp: request.timestamp,
      tenant_id: tenant_id,
      tenant_slug: tenant_slug
    }

    # Process each service status
    services
    |> Enum.reject(&is_nil/1)
    |> Enum.each(fn service ->
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
    peer_ip = get_peer_ip(stream)

    {total_services, saw_final?, _stream_agent_id} =
      Enum.reduce_while(request_stream, {0, false, nil}, fn chunk, {acc, _saw_final?, stream_agent_id} ->
        agent_id =
          chunk.agent_id
          |> to_string()
          |> String.trim()

        if agent_id == "" do
          raise GRPC.RPCError, status: :invalid_argument, message: "agent_id is required"
        end

        stream_agent_id =
          case stream_agent_id do
            nil -> agent_id
            ^agent_id -> agent_id
            _ -> raise GRPC.RPCError, status: :invalid_argument, message: "agent_id changed mid-stream"
          end
        services =
          chunk.services
          |> List.wrap()
          |> Enum.reject(&is_nil/1)

        service_count = length(services)
        new_total = acc + service_count

        if new_total > @max_services_per_request do
          raise GRPC.RPCError,
            status: :resource_exhausted,
            message:
              "too many service statuses in one stream (max: #{@max_services_per_request})"
        end

        chunk_index = chunk.chunk_index || 0
        total_chunks = chunk.total_chunks || 0

        if total_chunks <= 0 do
          raise GRPC.RPCError, status: :invalid_argument, message: "total_chunks must be > 0"
        end

        if chunk_index < 0 or chunk_index >= total_chunks do
          raise GRPC.RPCError, status: :invalid_argument, message: "invalid chunk_index"
        end

        Logger.debug(
          "Received chunk #{chunk_index + 1}/#{total_chunks} from agent #{agent_id} (tenant: #{tenant_slug})"
        )

        partition = normalize_partition(chunk.partition)

        # Extract metadata from chunk including tenant context from mTLS cert
        # Use server's gateway_id() instead of client-provided chunk.gateway_id
        # to prevent spoofing and ensure correct data attribution
        metadata = %{
          agent_id: agent_id,
          gateway_id: gateway_id(),
          partition: partition,
          source_ip: peer_ip,
          kv_store_id: chunk.kv_store_id,
          timestamp: System.os_time(:second),
          agent_timestamp: chunk.timestamp,
          chunk_index: chunk.chunk_index,
          total_chunks: chunk.total_chunks,
          is_final: chunk.is_final,
          tenant_id: tenant_id,
          tenant_slug: tenant_slug
        }

        # Process each service status in the chunk
        Enum.each(services, fn service ->
          process_service_status(service, metadata)
        end)

        if chunk.is_final do
          if chunk_index != total_chunks - 1 do
            raise GRPC.RPCError,
              status: :invalid_argument,
              message: "final chunk_index does not match total_chunks"
          end

          record_push_metrics(agent_id, new_total)
          {:halt, {new_total, true, stream_agent_id}}
        else
          {:cont, {new_total, false, stream_agent_id}}
        end
      end)

    if not saw_final? do
      raise GRPC.RPCError, status: :invalid_argument, message: "stream ended without final chunk"
    end

    Logger.info("Completed streaming status reception: #{total_services} total services")

    %Monitoring.GatewayStatusResponse{received: true}
  end

  # Process a single service status and forward to the core
  defp process_service_status(service, metadata) do
    # Tenant and gateway_id come from server-side metadata (mTLS cert + server identity)
    # NOT from the service message - this prevents spoofing
    service_name =
      service.service_name
      |> to_string()
      |> String.trim()

    if service_name == "" do
      raise GRPC.RPCError, status: :invalid_argument, message: "service_name is required"
    end

    message =
      service.message
      |> to_string()
      |> then(fn msg ->
        if byte_size(msg) > 4_096 do
          binary_part(msg, 0, 4_096)
        else
          msg
        end
      end)

    status = %{
      service_name: service_name,
      available: service.available == true,
      message: message,
      service_type: service.service_type,
      response_time: service.response_time,
      agent_id: metadata.agent_id,
      gateway_id: metadata.gateway_id,
      partition: normalize_partition(service.partition || metadata.partition),
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

  defp normalize_partition(partition) when is_binary(partition) do
    partition = String.trim(partition)

    if byte_size(partition) > 0 and byte_size(partition) <= 128 and
         not String.contains?(partition, ["\n", "\r", "\t"]) do
      partition
    else
      "default"
    end
  end

  defp normalize_partition(_partition), do: "default"

  # Record metrics for the push operation
  defp record_push_metrics(agent_id, service_count) do
    # TODO: Integrate with telemetry/metrics system
    Logger.debug("Recorded push metrics: agent=#{agent_id} services=#{service_count}")
  end

  # Extract tenant info from the gRPC stream's mTLS certificate
  # Uses TenantResolver to properly validate and extract tenant identity
  # Rejects requests without valid mTLS to prevent multi-tenant security vulnerabilities
  defp extract_tenant_from_stream(stream) do
    with {:ok, cert_der} <- get_peer_cert(stream),
         {:ok, %{tenant_id: tenant_id, tenant_slug: tenant_slug}} <-
           TenantResolver.resolve_from_cert(cert_der),
         true <- not is_nil(tenant_id) do
      {tenant_id, tenant_slug}
    else
      {:ok, %{tenant_slug: tenant_slug}} when not is_nil(tenant_slug) ->
        # If tenant_id cannot be resolved (e.g., issuer lookup unavailable), do not silently
        # accept writes under a shared tenant; reject to avoid cross-tenant data leakage.
        Logger.warning("Tenant resolution failed: tenant_slug=#{tenant_slug} but no tenant_id")
        raise GRPC.RPCError, status: :unauthenticated, message: "tenant_id resolution required"

      {:error, reason} ->
        Logger.warning("Tenant resolution failed: #{inspect(reason)}")
        raise GRPC.RPCError, status: :unauthenticated, message: "invalid client certificate"

      false ->
        Logger.warning("Tenant resolution failed: tenant_id is nil")
        raise GRPC.RPCError, status: :unauthenticated, message: "invalid client certificate"
    end
  end

  # Get the peer certificate from the gRPC stream
  # Uses the adapter's built-in get_cert function which calls :cowboy_req.cert(req)
  defp get_peer_cert(stream) do
    try do
      adapter = stream.adapter
      payload = stream.payload

      # Check if the adapter supports certificate extraction
      if is_atom(adapter) and function_exported?(adapter, :get_cert, 1) do
        case adapter.get_cert(payload) do
          :undefined ->
            {:error, :no_certificate}

          cert_der when is_binary(cert_der) ->
            {:ok, cert_der}

          other ->
            {:error, {:unexpected_cert_result, other}}
        end
      else
        {:error, {:cert_extraction_unsupported, adapter}}
      end
    rescue
      e -> {:error, {:extraction_failed, Exception.message(e)}}
    catch
      kind, reason -> {:error, {:extraction_failed, kind, inspect(reason)}}
    end
  end

  defp get_peer_ip(stream) do
    try do
      adapter = stream.adapter
      payload = stream.payload

      cond do
        is_atom(adapter) and function_exported?(adapter, :get_peer, 1) ->
          normalize_peer(adapter.get_peer(payload))

        function_exported?(:cowboy_req, :peer, 1) ->
          normalize_peer(:cowboy_req.peer(payload))

        true ->
          nil
      end
    rescue
      _ -> nil
    end
  end

  defp normalize_peer({ip, _port}), do: ip_to_string(ip)
  defp normalize_peer(ip) when is_tuple(ip), do: ip_to_string(ip)
  defp normalize_peer(ip) when is_binary(ip), do: ip
  defp normalize_peer(_), do: nil

  defp ip_to_string(ip) do
    ip
    |> :inet.ntoa()
    |> to_string()
  end
end
