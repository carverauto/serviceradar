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

  alias ServiceRadar.Cluster.TenantRegistry
  alias ServiceRadar.Edge.AgentGatewaySync
  alias ServiceRadar.Edge.TenantResolver
  alias ServiceRadarAgentGateway.AgentRegistryProxy
  alias ServiceRadarAgentGateway.Config
  alias ServiceRadarAgentGateway.StatusProcessor

  # Default heartbeat interval for agents
  @default_heartbeat_interval_sec 30

  # Maximum services per push request to prevent resource exhaustion
  @max_services_per_request 5_000
  @max_status_message_bytes 4_096
  @max_results_message_bytes 15 * 1024 * 1024

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
    tenant_info = extract_tenant_from_stream(stream)
    partition_id = resolve_partition(tenant_info, request.partition)
    capabilities = normalize_capabilities(request.capabilities || [])

    ensure_agent_record(tenant_info, agent_id, partition_id, request, get_peer_ip(stream))
    ensure_agent_registered(tenant_info, agent_id, partition_id, capabilities, stream)

    # Registration is stored in the tenant registry and DB; acceptance remains cert-based.

    # Check if config is outdated (placeholder - always false for now)
    # TODO: Implement config versioning in core-elx
    config_outdated = request.config_version == "" or request.config_version == nil

    Logger.info(
      "Agent enrolled: agent_id=#{agent_id}, tenant=#{tenant_info.tenant_slug}, config_outdated=#{config_outdated}"
    )

    %Monitoring.AgentHelloResponse{
      accepted: true,
      agent_id: agent_id,
      message: "Agent enrolled successfully",
      gateway_id: gateway_id(),
      server_time: System.os_time(:second),
      heartbeat_interval_sec: @default_heartbeat_interval_sec,
      config_outdated: config_outdated,
      tenant_id: tenant_info.tenant_id,
      tenant_slug: tenant_info.tenant_slug
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
    tenant_info = extract_tenant_from_stream(stream)

    # Generate config from database using the config generator
    case core_call(AgentGatewaySync, :get_config_if_changed, [
           agent_id,
           tenant_info.tenant_id,
           config_version
         ]) do
      {:error, :core_unavailable} ->
        raise GRPC.RPCError, status: :unavailable, message: "core unavailable"

      {:ok, :not_modified} ->
        Logger.debug("Agent config not modified: agent_id=#{agent_id}, version=#{config_version}")

        %Monitoring.AgentConfigResponse{
          not_modified: true,
          config_version: config_version
        }

      {:ok, {:ok, config}} ->
        Logger.info(
          "Sending config to agent: agent_id=#{agent_id}, tenant=#{tenant_info.tenant_slug}, version=#{config.config_version}, checks=#{length(config.checks)}"
        )

        # Convert checks to proto format
        proto_checks = ServiceRadar.Edge.AgentConfigGenerator.to_proto_checks(config.checks)

        config_json = Map.get(config, :config_json, <<>>)

        %Monitoring.AgentConfigResponse{
          not_modified: false,
          config_version: config.config_version,
          config_timestamp: config.config_timestamp,
          heartbeat_interval_sec: config.heartbeat_interval_sec,
          config_poll_interval_sec: config.config_poll_interval_sec,
          checks: proto_checks,
          config_json: config_json
        }

      {:ok, {:error, reason}} ->
        Logger.warning(
          "Failed to generate config for agent #{agent_id}: #{inspect(reason)}, returning empty config"
        )

        %Monitoring.AgentConfigResponse{
          not_modified: false,
          config_version: "v0-error",
          config_timestamp: System.os_time(:second),
          heartbeat_interval_sec: @default_heartbeat_interval_sec,
          config_poll_interval_sec: 300,
          checks: []
        }

      {:ok, other} ->
        Logger.warning("Unexpected config response for agent #{agent_id}: #{inspect(other)}")

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
    tenant_info = extract_tenant_from_stream(stream)
    partition = resolve_partition(tenant_info, request.partition)

    refresh_agent_heartbeat(tenant_info, agent_id, partition, request, stream)

    Logger.info(
      "Received status push from agent #{agent_id}: #{service_count} services (tenant: #{tenant_info.tenant_slug})"
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
      tenant_id: tenant_info.tenant_id,
      tenant_slug: tenant_info.tenant_slug
    }

    # Process each service status
    processed_count =
      services
      |> Enum.reject(&is_nil/1)
      |> Enum.reduce(0, fn
        %Monitoring.GatewayServiceStatus{} = service, acc ->
          try do
            process_service_status(service, metadata)
            acc + 1
          rescue
            e in GRPC.RPCError ->
              Logger.warning(
                "Dropping invalid service status from agent #{metadata.agent_id}: #{e.status} #{e.message}"
              )

              acc

            e ->
              Logger.warning(
                "Dropping service status from agent #{metadata.agent_id} due to error: #{Exception.message(e)}"
              )

              acc
          end

        _other, acc ->
          acc
      end)

    if processed_count == 0 and service_count > 0 do
      raise GRPC.RPCError, status: :invalid_argument, message: "no valid service statuses"
    end

    # Record metrics
    record_push_metrics(agent_id, processed_count)

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
    tenant_info = extract_tenant_from_stream(stream)
    peer_ip = get_peer_ip(stream)

    {total_services, saw_final?, _stream_agent_id, _expected_idx, _pinned_total_chunks, _registered?} =
      Enum.reduce_while(request_stream, {0, false, nil, 0, nil, false}, fn chunk,
                                                                        {acc, _saw_final?, stream_agent_id,
                                                                         expected_idx, pinned_total_chunks,
                                                                         registered?} ->
        agent_id =
          case chunk.agent_id do
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

        pinned_total_chunks =
          case pinned_total_chunks do
            nil -> total_chunks
            ^total_chunks -> total_chunks
            _ -> raise GRPC.RPCError, status: :invalid_argument, message: "total_chunks changed mid-stream"
          end

        if chunk_index < 0 or chunk_index >= total_chunks do
          raise GRPC.RPCError, status: :invalid_argument, message: "invalid chunk_index"
        end

        if chunk_index != expected_idx do
          raise GRPC.RPCError, status: :invalid_argument, message: "unexpected chunk_index"
        end

        Logger.debug(
          "Received chunk #{chunk_index + 1}/#{total_chunks} from agent #{agent_id} (tenant: #{tenant_info.tenant_slug})"
        )

        partition = resolve_partition(tenant_info, chunk.partition)

        if not registered? do
          refresh_agent_heartbeat(tenant_info, agent_id, partition, chunk, stream)
        end

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
          chunk_index: chunk_index,
          total_chunks: total_chunks,
          is_final: chunk.is_final,
          tenant_id: tenant_info.tenant_id,
          tenant_slug: tenant_info.tenant_slug
        }

        # Process each service status in the chunk
        Enum.each(services, fn service ->
          try do
            process_service_status(service, metadata)
          rescue
            e in GRPC.RPCError ->
              Logger.warning(
                "Dropping invalid service status from agent #{metadata.agent_id}: #{e.status} #{e.message}"
              )

            e ->
              Logger.warning(
                "Dropping service status from agent #{metadata.agent_id} due to error: #{Exception.message(e)}"
              )
          end
        end)

        if chunk.is_final do
          if chunk_index != total_chunks - 1 do
            raise GRPC.RPCError,
              status: :invalid_argument,
              message: "final chunk_index does not match total_chunks"
          end

          record_push_metrics(agent_id, new_total)
          {:halt,
           {new_total, true, stream_agent_id, expected_idx + 1, pinned_total_chunks, true}}
        else
          {:cont,
           {new_total, false, stream_agent_id, expected_idx + 1, pinned_total_chunks, true}}
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
      case service.service_name do
        name when is_binary(name) -> String.trim(name)
        nil -> ""
        _ -> ""
      end

    service_type =
      case service.service_type do
        st when is_binary(st) -> String.trim(st)
        _ -> ""
      end

    source =
      case service.source do
        src when is_binary(src) -> String.trim(src)
        _ -> ""
      end

    cond do
      service_name == "" ->
        raise GRPC.RPCError, status: :invalid_argument, message: "service_name is required"

      byte_size(service_name) > 255 ->
        raise GRPC.RPCError, status: :invalid_argument, message: "service_name is too long"

      String.contains?(service_name, ["\n", "\r", "\t"]) ->
        raise GRPC.RPCError, status: :invalid_argument, message: "service_name contains invalid characters"

      byte_size(service_type) > 64 or String.contains?(service_type, ["\n", "\r", "\t"]) ->
        raise GRPC.RPCError, status: :invalid_argument, message: "service_type is invalid"

      byte_size(source) > 64 or String.contains?(source, ["\n", "\r", "\t"]) ->
        raise GRPC.RPCError, status: :invalid_argument, message: "source is invalid"

      true ->
        :ok
    end

    message =
      case service.message do
        nil ->
          ""

        msg when is_binary(msg) ->
          msg

        msg when is_list(msg) ->
          IO.iodata_to_binary(msg)

        _ ->
          ""
      end
      |> normalize_message(source)

    response_time =
      case service.response_time do
        rt when is_integer(rt) and rt >= 0 and rt <= 86_400_000 ->
          rt

        rt when is_integer(rt) and rt > 86_400_000 ->
          86_400_000

        _ ->
          0
      end

    status = %{
      service_name: service_name,
      available: service.available == true,
      message: message,
      service_type: service_type,
      response_time: response_time,
      agent_id: metadata.agent_id,
      gateway_id: metadata.gateway_id,
      partition: normalize_partition(service.partition || metadata.partition),
      source: source,
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

  defp normalize_message(msg, source) do
    max_bytes =
      case source do
        "results" -> @max_results_message_bytes
        _ -> @max_status_message_bytes
      end

    if byte_size(msg) > max_bytes do
      if source == "results" do
        raise GRPC.RPCError,
          status: :resource_exhausted,
          message: "results payload exceeds max size"
      else
        binary_part(msg, 0, @max_status_message_bytes)
      end
    else
      msg
    end
  end

  defp normalize_partition(_partition), do: "default"

  # Record metrics for the push operation
  defp record_push_metrics(agent_id, service_count) do
    # TODO: Integrate with telemetry/metrics system
    Logger.debug("Recorded push metrics: agent=#{agent_id} services=#{service_count}")
  end

  defp normalize_capabilities(capabilities) do
    capabilities
    |> List.wrap()
    |> Enum.map(fn
      cap when is_binary(cap) -> String.trim(cap)
      cap -> to_string(cap)
    end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp resolve_partition(tenant_info, request_partition) do
    tenant_partition =
      case tenant_info do
        %{partition_id: partition_id} -> partition_id
        _ -> nil
      end

    normalize_partition(tenant_partition || request_partition)
  end

  defp ensure_agent_registered(tenant_info, agent_id, partition_id, capabilities, stream) do
    metadata =
      agent_registry_metadata(tenant_info, partition_id, capabilities, stream)

    case AgentRegistryProxy.touch_agent(tenant_info.tenant_id, agent_id, metadata) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Failed to register agent #{agent_id} in registry: #{inspect(reason)}"
        )

        raise GRPC.RPCError, status: :unavailable, message: "agent registry unavailable"
    end
  end

  defp refresh_agent_heartbeat(tenant_info, agent_id, partition_id, request, stream) do
    _ = ensure_agent_registered(tenant_info, agent_id, partition_id, nil, stream)

    source_ip =
      case request do
        %{source_ip: source_ip} when is_binary(source_ip) and source_ip != "" -> source_ip
        _ -> get_peer_ip(stream)
      end

    touch_agent_record(tenant_info, agent_id, partition_id, source_ip)
  end

  defp agent_registry_metadata(tenant_info, partition_id, capabilities, stream) do
    metadata = %{
      partition_id: partition_id,
      domain: Config.domain(),
      capabilities: capabilities,
      status: :connected,
      spiffe_id: tenant_info.spiffe_id,
      gateway_id: Config.gateway_id(),
      source_ip: get_peer_ip(stream)
    }

    compact_metadata(metadata)
  end

  defp ensure_agent_record(tenant_info, agent_id, partition_id, request, source_ip) do
    attrs = agent_record_attrs(agent_id, partition_id, request, source_ip, tenant_info)

    case core_call(AgentGatewaySync, :upsert_agent, [agent_id, tenant_info.tenant_id, attrs]) do
      {:ok, :ok} ->
        :ok

      {:ok, {:error, reason}} ->
        Logger.warning("Failed to upsert agent record #{agent_id}: #{inspect(reason)}")
        raise GRPC.RPCError, status: :unavailable, message: "core unavailable"

      {:error, :core_unavailable} ->
        raise GRPC.RPCError, status: :unavailable, message: "core unavailable"
    end
  end

  defp touch_agent_record(tenant_info, agent_id, partition_id, source_ip) do
    attrs = agent_record_attrs(agent_id, partition_id, nil, source_ip, tenant_info)

    case core_call(AgentGatewaySync, :heartbeat_agent, [agent_id, tenant_info.tenant_id, attrs]) do
      {:ok, :ok} ->
        :ok

      {:ok, {:error, reason}} ->
        Logger.warning("Failed to heartbeat agent record #{agent_id}: #{inspect(reason)}")
        :ok

      {:error, :core_unavailable} ->
        Logger.warning("Core unavailable while updating agent #{agent_id}")
        :ok
    end
  end

  defp agent_record_attrs(agent_id, partition_id, request, source_ip, tenant_info) do
    metadata =
      %{
        gateway_id: Config.gateway_id(),
        partition_id: partition_id,
        domain: Config.domain(),
        source_ip: source_ip
      }
      |> Map.merge(request_metadata(request))
      |> compact_metadata()

    %{
      uid: agent_id,
      name: request_value(request, :hostname),
      version: request_value(request, :version),
      type_id: 4,
      capabilities: request_capabilities(request),
      host: source_ip,
      spiffe_identity: tenant_info.spiffe_id,
      metadata: metadata
    }
    |> compact_metadata()
  end

  defp request_capabilities(request) do
    case request do
      %{capabilities: capabilities} -> normalize_capabilities(capabilities)
      _ -> []
    end
  end

  defp request_metadata(request) do
    base = %{
      hostname: request_value(request, :hostname),
      os: request_value(request, :os),
      arch: request_value(request, :arch),
      labels: request_value(request, :labels)
    }

    compact_metadata(base)
  end

  defp request_value(request, key) do
    case request do
      nil -> nil
      %{^key => value} when is_binary(value) and value != "" -> value
      %{^key => value} when is_map(value) and map_size(value) > 0 -> value
      %{^key => value} when is_list(value) and value != [] -> value
      _ -> nil
    end
  end

  defp compact_metadata(metadata) do
    metadata
    |> Enum.reject(fn
      {_key, nil} -> true
      {_key, ""} -> true
      {_key, []} -> true
      {_key, %{} = value} -> map_size(value) == 0
      _ -> false
    end)
    |> Map.new()
  end

  defp core_call(module, function, args, timeout \\ 5_000) do
    nodes = core_nodes()

    if nodes == [] do
      {:error, :core_unavailable}
    else
      Enum.reduce_while(nodes, {:error, :core_unavailable}, fn node, _acc ->
        case :rpc.call(node, module, function, args, timeout) do
          {:badrpc, _} ->
            {:cont, {:error, :core_unavailable}}

          result ->
            {:halt, {:ok, result}}
        end
      end)
    end
  end

  defp core_nodes do
    nodes = [Node.self() | Node.list()] |> Enum.uniq()

    coordinators =
      Enum.filter(nodes, fn node ->
        case :rpc.call(node, Process, :whereis, [ServiceRadar.ClusterHealth], 5_000) do
          pid when is_pid(pid) -> true
          _ -> false
        end
      end)

    if coordinators != [] do
      coordinators
    else
      Enum.filter(nodes, fn node ->
        case :rpc.call(node, Process, :whereis, [ServiceRadar.Repo], 5_000) do
          pid when is_pid(pid) -> true
          _ -> false
        end
      end)
    end
  end

  # Extract tenant info from the gRPC stream's mTLS certificate
  # Uses TenantResolver to properly validate and extract tenant identity
  # Rejects requests without valid mTLS to prevent multi-tenant security vulnerabilities
  defp extract_tenant_from_stream(stream) do
    with {:ok, cert_der} <- get_peer_cert(stream),
         {:ok, resolved} <- TenantResolver.resolve_from_cert(cert_der),
         {:ok, tenant_id} <- resolve_tenant_id(resolved),
         tenant_slug when is_binary(tenant_slug) and tenant_slug != "" <- resolved.tenant_slug do
      resolved
      |> Map.put(:tenant_id, tenant_id)
      |> Map.put(:tenant_slug, tenant_slug)
    else
      {:error, :tenant_slug_missing} ->
        Logger.warning("Tenant resolution failed: tenant_slug missing from client certificate")
        raise GRPC.RPCError, status: :unauthenticated, message: "invalid client certificate"

      {:error, {:tenant_id_not_found, tenant_slug}} ->
        Logger.warning(
          "Tenant resolution failed: tenant_id not found for tenant_slug=#{tenant_slug}"
        )
        raise GRPC.RPCError, status: :unauthenticated, message: "invalid client certificate"

      {:error, reason} ->
        Logger.warning("Tenant resolution failed: #{inspect(reason)}")
        raise GRPC.RPCError, status: :unauthenticated, message: "invalid client certificate"

      _ ->
        Logger.warning("Tenant resolution failed: invalid tenant identity")
        raise GRPC.RPCError, status: :unauthenticated, message: "invalid client certificate"
    end
  end

  defp resolve_tenant_id(%{tenant_id: tenant_id}) when is_binary(tenant_id) and tenant_id != "" do
    {:ok, tenant_id}
  end

  defp resolve_tenant_id(%{tenant_slug: tenant_slug}) when is_binary(tenant_slug) and tenant_slug != "" do
    case TenantRegistry.tenant_id_for_slug(tenant_slug) do
      {:ok, tenant_id} ->
        {:ok, tenant_id}

      :error ->
        resolve_tenant_id_from_cluster(tenant_slug)
    end
  end

  defp resolve_tenant_id(_resolved), do: {:error, :tenant_slug_missing}

  defp resolve_tenant_id_from_cluster(tenant_slug) do
    nodes = Node.list()

    if nodes == [] do
      {:error, {:tenant_id_not_found, tenant_slug}}
    else
      {results, _bad_nodes} =
        :rpc.multicall(nodes, TenantRegistry, :tenant_id_for_slug, [tenant_slug], 5_000)

      case Enum.find(results, &match?({:ok, _}, &1)) do
        {:ok, tenant_id} -> {:ok, tenant_id}
        _ -> {:error, {:tenant_id_not_found, tenant_slug}}
      end
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
