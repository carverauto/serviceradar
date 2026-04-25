defmodule ServiceRadarAgentGateway.AgentGatewayServer do
  @moduledoc """
  gRPC server that receives status pushes from Go agents.

  ## Architecture

  Agents initiate all connections to the gateway (gateway never connects back).
  This ensures:
  - Agents can connect outbound through firewalls
  - No inbound firewall rules needed in customer networks
  - Secure communication via mTLS

  ## Component Identity

  Component identity (component_id, partition_id, component_type) is extracted
  from the mTLS client certificate. The certificate contains:
  - CN: `<component_id>.<partition_id>.serviceradar`
  - SPIFFE URI SAN: `spiffe://serviceradar.local/<component_type>/...`

  Deployments are isolated at the infrastructure level; the gateway does not
  validate any deployment identifier in the certificate.

  ## Protocol

  The server implements the AgentGatewayService:
  - `PushStatus`: Receives a batch of service statuses from an agent
  - `StreamStatus`: Receives streaming chunks of service statuses

  ## Usage

  The server is started automatically by the application supervisor.
  Incoming status updates are forwarded to the core cluster for processing.
  """

  use GRPC.Server, service: Monitoring.AgentGatewayService.Service

  alias ServiceRadar.Edge.AgentConfigGenerator
  alias ServiceRadar.Edge.AgentGatewaySync
  alias ServiceRadarAgentGateway.AgentRegistryProxy
  alias ServiceRadarAgentGateway.ComponentIdentityResolver
  alias ServiceRadarAgentGateway.Config
  alias ServiceRadarAgentGateway.ControlStreamSession
  alias ServiceRadarAgentGateway.StatusProcessor

  require Logger

  # Default heartbeat interval for agents
  @default_heartbeat_interval_sec 30

  # Maximum services per push request to prevent resource exhaustion
  @max_services_per_request 5_000
  @max_status_message_bytes 4_096
  @max_results_message_bytes 15 * 1024 * 1024
  @max_sysmon_message_bytes 15 * 1024 * 1024
  @agent_gateway_component_types [:agent]

  # Gateway identifier (node name or configured ID)
  defp gateway_id do
    Atom.to_string(node())
  end

  defp required_agent_id(value) do
    case value do
      nil ->
        raise GRPC.RPCError, status: :invalid_argument, message: "agent_id is required"

      value ->
        case value |> to_string() |> String.trim() do
          "" ->
            raise GRPC.RPCError, status: :invalid_argument, message: "agent_id is required"

          agent_id ->
            agent_id
        end
    end
  end

  defp config_outdated?(nil), do: true
  defp config_outdated?(""), do: true
  defp config_outdated?(_), do: false

  @doc """
  Handle an agent hello/enrollment request.

  Called by the agent on startup to announce itself and register with the gateway.
  Validates the mTLS certificate, extracts component identity, and registers the agent.
  """
  @spec hello(Monitoring.AgentHelloRequest.t(), GRPC.Server.Stream.t()) ::
          Monitoring.AgentHelloResponse.t()
  def hello(request, stream) do
    agent_id = required_agent_id(request.agent_id)
    version = request.version
    capabilities = request.capabilities || []

    Logger.info("Agent hello received: agent_id=#{agent_id}, version=#{version}")
    Logger.debug("Agent capabilities: #{inspect(capabilities)}")

    # Extract identity from mTLS certificate (secure source of truth)
    identity = extract_identity_from_stream(stream)
    {identity, _component_type} = resolve_component_type!(identity, agent_id)
    enforce_component_identity!(identity, agent_id, @agent_gateway_component_types)
    partition_id = resolve_partition(identity, request.partition)
    capabilities = normalize_capabilities(request.capabilities || [])
    source_ip = get_peer_ip(stream)

    ensure_agent_record(identity, agent_id, partition_id, request, source_ip)
    ensure_device_for_agent(identity, agent_id, partition_id, request, source_ip)
    ensure_agent_registered(identity, agent_id, partition_id, capabilities, stream)
    track_connected_agent(agent_id, partition_id, request, source_ip)

    # Registration is stored in the registry and DB; acceptance remains cert-based.
    config_outdated = config_outdated?(request.config_version)

    Logger.info("Agent enrolled: agent_id=#{agent_id}, config_outdated=#{config_outdated}")

    %Monitoring.AgentHelloResponse{
      accepted: true,
      agent_id: agent_id,
      message: "Agent enrolled successfully",
      gateway_id: gateway_id(),
      server_time: System.os_time(:second),
      heartbeat_interval_sec: @default_heartbeat_interval_sec,
      config_outdated: config_outdated
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
    agent_id = required_agent_id(request.agent_id)
    config_version = request.config_version || ""

    Logger.debug("Agent config request: agent_id=#{agent_id}, version=#{config_version}")

    # Extract identity from mTLS certificate for authorization
    identity = extract_identity_from_stream(stream)
    {identity, component_type} = resolve_component_type!(identity, agent_id)
    enforce_component_identity!(identity, agent_id, @agent_gateway_component_types)

    Logger.info("Config request received: component_type=#{component_type}, agent_id=#{agent_id}")

    # Generate config from database using the config generator
    AgentGatewaySync
    |> core_call(:get_config_if_changed, [agent_id, config_version], 15_000)
    |> handle_config_response(agent_id, config_version)
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

    # Extract identity from mTLS certificate (secure source of truth)
    identity = extract_identity_from_stream(stream)
    enforce_component_identity!(identity, agent_id, @agent_gateway_component_types)
    partition = resolve_partition(identity, request.partition)

    refresh_agent_heartbeat(identity, agent_id, partition, request, stream)

    Logger.info("Received status push from agent #{agent_id}: #{service_count} services")

    # Extract metadata from request
    # Use server's gateway_id() instead of client-provided request.gateway_id
    # to prevent spoofing and ensure correct data attribution
    metadata = %{
      agent_id: agent_id,
      gateway_id: gateway_id(),
      partition: partition,
      source_ip: get_peer_ip(stream),
      kv_store_id: request.kv_store_id,
      timestamp: System.os_time(:second),
      agent_timestamp: request.timestamp
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
              log_invalid_service_status(metadata, service, e)

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
    reconcile_agent_release(agent_id)

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

    # Extract identity from mTLS certificate once for all chunks
    identity = extract_identity_from_stream(stream)
    peer_ip = get_peer_ip(stream)

    state =
      Enum.reduce_while(request_stream, initial_stream_status_state(), fn chunk, state ->
        handle_status_chunk(chunk, state, identity, peer_ip, stream)
      end)

    if not state.saw_final? do
      raise GRPC.RPCError, status: :invalid_argument, message: "stream ended without final chunk"
    end

    Logger.info("Completed streaming status reception: #{state.total_services} total services")

    %Monitoring.GatewayStatusResponse{received: true}
  end

  @doc """
  Handle the bidirectional control stream from an agent.
  """
  @spec control_stream(Enumerable.t(), GRPC.Server.Stream.t()) :: :ok
  def control_stream(request_stream, stream) do
    identity = extract_identity_from_stream(stream)

    session_pid =
      request_stream
      |> Enum.reduce_while({:awaiting_hello, nil}, fn message, state ->
        handle_control_stream_message(message, state, identity, stream)
      end)
      |> control_session_pid()

    if is_pid(session_pid) do
      GenServer.stop(session_pid, :normal)
    end

    :ok
  end

  # Process a single service status and forward to the core
  defp process_service_status(service, metadata) do
    # Validation is done by mTLS certificate verification and deployment isolation.
    {service_name, service_type, source} = normalized_service_fields(service)
    validate_service_fields!(service_name, service_type, source)

    status =
      build_service_status(
        service,
        metadata,
        service_name,
        service_type,
        source
      )

    forward_service_status(service, status)
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

  defp normalized_service_fields(service) do
    {
      normalize_service_field(service.service_name),
      normalize_service_field(service.service_type),
      normalize_service_field(service.source)
    }
  end

  defp normalize_service_field(value) when is_binary(value), do: String.trim(value)
  defp normalize_service_field(_), do: ""

  defp validate_service_fields!(service_name, service_type, source) do
    cond do
      service_name == "" ->
        raise GRPC.RPCError, status: :invalid_argument, message: "service_name is required"

      invalid_service_name?(service_name) ->
        raise GRPC.RPCError, status: :invalid_argument, message: "service_name is invalid"

      invalid_service_field?(service_type, 64) ->
        raise GRPC.RPCError, status: :invalid_argument, message: "service_type is invalid"

      invalid_service_field?(source, 64) ->
        raise GRPC.RPCError, status: :invalid_argument, message: "source is invalid"

      true ->
        :ok
    end
  end

  defp invalid_service_name?(service_name) do
    byte_size(service_name) > 255 or contains_control_chars?(service_name)
  end

  defp invalid_service_field?(value, max_bytes) do
    byte_size(value) > max_bytes or contains_control_chars?(value)
  end

  defp contains_control_chars?(value) do
    String.contains?(value, ["\n", "\r", "\t"])
  end

  defp build_service_status(service, metadata, service_name, service_type, source) do
    %{
      service_name: service_name,
      available: service.available == true,
      message: normalize_service_message(service.message, source),
      service_type: service_type,
      response_time: normalize_response_time(service.response_time),
      agent_id: metadata.agent_id,
      gateway_id: metadata.gateway_id,
      partition: normalize_partition(service.partition || metadata.partition),
      source: source,
      kv_store_id: service.kv_store_id || metadata.kv_store_id,
      timestamp: metadata.timestamp,
      agent_timestamp: metadata.agent_timestamp,
      chunk_index: Map.get(metadata, :chunk_index, 0),
      total_chunks: Map.get(metadata, :total_chunks, 1),
      is_final: Map.get(metadata, :is_final, true)
    }
  end

  defp normalize_service_message(nil, source), do: normalize_message("", source)

  defp normalize_service_message(message, source) when is_binary(message),
    do: normalize_message(message, source)

  defp normalize_service_message(message, source) when is_list(message),
    do: message |> IO.iodata_to_binary() |> normalize_message(source)

  defp normalize_service_message(_, source), do: normalize_message("", source)

  defp normalize_response_time(rt) when is_integer(rt) and rt >= 0 and rt <= 86_400_000, do: rt
  defp normalize_response_time(rt) when is_integer(rt) and rt > 86_400_000, do: 86_400_000
  defp normalize_response_time(_), do: 0

  defp forward_service_status(service, status) do
    case StatusProcessor.process(status) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Failed to process status for service #{service.service_name}: #{inspect(reason)}"
        )
    end
  end

  defp log_invalid_service_status(metadata, service, %GRPC.RPCError{} = error) do
    Logger.warning(
      "Dropping invalid service status from agent #{metadata.agent_id}: #{error.status} #{error.message} " <>
        "#{inspect(service_log_fields(service))}"
    )
  end

  defp service_log_fields(service) do
    %{
      service_name: normalize_log_value(service.service_name),
      service_type: normalize_log_value(service.service_type),
      source: normalize_log_value(service.source),
      available: service.available,
      response_time: service.response_time,
      message_bytes: message_size(service.message)
    }
  end

  defp normalize_log_value(nil), do: nil
  defp normalize_log_value(value) when is_binary(value), do: String.trim(value)
  defp normalize_log_value(value), do: to_string(value)

  defp message_size(value) when is_binary(value), do: byte_size(value)
  defp message_size(_), do: 0

  defp normalize_message(msg, source) do
    max_bytes =
      case source do
        "results" -> @max_results_message_bytes
        "sysmon-metrics" -> @max_sysmon_message_bytes
        "snmp-metrics" -> @max_results_message_bytes
        "plugin-result" -> @max_results_message_bytes
        _ -> @max_status_message_bytes
      end

    if byte_size(msg) > max_bytes do
      if source in ["results", "sysmon-metrics", "snmp-metrics", "plugin-result"] do
        raise GRPC.RPCError,
          status: :resource_exhausted,
          message: "payload exceeds max size"
      else
        binary_part(msg, 0, @max_status_message_bytes)
      end
    else
      msg
    end
  end

  # Record metrics for the push operation
  defp record_push_metrics(agent_id, service_count) do
    :telemetry.execute(
      [:serviceradar, :agent_gateway, :push, :complete],
      %{service_count: service_count},
      %{
        agent_id: agent_id,
        gateway_id: Config.gateway_id(),
        domain: Config.domain()
      }
    )
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

  defp resolve_partition(identity, _request_partition) do
    partition_id = Map.fetch!(identity, :partition_id)
    normalize_partition(partition_id)
  end

  defp resolve_component_type!(identity, component_id) do
    case Map.get(identity, :component_type) do
      component_type when is_atom(component_type) ->
        {identity, component_type}

      nil ->
        Logger.warning(
          "Component type missing from client certificate: component_id=#{component_id}"
        )

        raise GRPC.RPCError, status: :permission_denied, message: "component_type missing"

      _ ->
        Logger.warning(
          "Invalid component type in client certificate: component_id=#{component_id}"
        )

        raise GRPC.RPCError, status: :permission_denied, message: "invalid component_type"
    end
  end

  defp enforce_component_identity!(identity, component_id, allowed_types) do
    cert_component_id =
      identity
      |> Map.fetch!(:component_id)
      |> String.trim()

    if cert_component_id == "" do
      Logger.warning("Component identity missing from client certificate")
      raise GRPC.RPCError, status: :unauthenticated, message: "invalid client certificate"
    end

    if component_id != cert_component_id do
      Logger.warning(
        "Component identity mismatch: request=#{component_id} cert=#{cert_component_id}"
      )

      raise GRPC.RPCError, status: :permission_denied, message: "component_id mismatch"
    end

    component_type = Map.get(identity, :component_type)

    cond do
      is_nil(component_type) ->
        :ok

      component_type in allowed_types ->
        :ok

      true ->
        Logger.warning(
          "Component type not authorized: component_type=#{inspect(component_type)} allowed=#{inspect(allowed_types)}"
        )

        raise GRPC.RPCError, status: :permission_denied, message: "component_type not authorized"
    end
  end

  defp ensure_agent_registered(_identity, agent_id, partition_id, capabilities, stream) do
    metadata =
      agent_registry_metadata(partition_id, capabilities, stream)

    case AgentRegistryProxy.touch_agent(agent_id, metadata) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to register agent #{agent_id} in registry: #{inspect(reason)}")

        raise GRPC.RPCError, status: :unavailable, message: "agent registry unavailable"
    end
  end

  defp refresh_agent_heartbeat(identity, agent_id, partition_id, request, stream) do
    _ = ensure_agent_registered(identity, agent_id, partition_id, nil, stream)

    source_ip =
      case request do
        %{source_ip: source_ip} when is_binary(source_ip) and source_ip != "" -> source_ip
        _ -> get_peer_ip(stream)
      end

    track_connected_agent(agent_id, partition_id, request, source_ip)

    config_source = extract_config_source(request)

    touch_agent_record(identity, agent_id, partition_id, source_ip, config_source)
  end

  defp extract_config_source(request) do
    case request do
      %{config_source: source} when is_binary(source) ->
        parse_config_source(source)

      _ ->
        nil
    end
  end

  defp parse_config_source(source) do
    case String.trim(source) do
      "remote" -> :remote
      "local" -> :local
      "cached" -> :cached
      "unassigned" -> :unassigned
      "default" -> :unassigned
      _ -> nil
    end
  end

  defp agent_registry_metadata(partition_id, capabilities, stream) do
    metadata = %{
      partition_id: partition_id,
      domain: Config.domain(),
      capabilities: capabilities,
      status: :connected,
      gateway_id: Config.gateway_id(),
      source_ip: get_peer_ip(stream)
    }

    compact_metadata(metadata)
  end

  defp ensure_agent_record(_identity, agent_id, partition_id, request, source_ip) do
    attrs = agent_record_attrs(agent_id, partition_id, request, source_ip)

    case core_call(AgentGatewaySync, :upsert_agent, [agent_id, attrs]) do
      {:ok, :ok} ->
        :ok

      {:ok, {:error, reason}} ->
        Logger.warning("Failed to upsert agent record #{agent_id}: #{inspect(reason)}")
        raise GRPC.RPCError, status: :unavailable, message: "core unavailable"

      {:error, :core_unavailable} ->
        raise GRPC.RPCError, status: :unavailable, message: "core unavailable"
    end
  end

  defp ensure_device_for_agent(_identity, agent_id, partition_id, request, source_ip) do
    attrs = device_attrs_from_request(partition_id, request, source_ip)

    case core_call(AgentGatewaySync, :ensure_device_for_agent, [agent_id, attrs]) do
      {:ok, {:ok, device_uid}} ->
        Logger.debug("Agent #{agent_id} linked to device #{device_uid}")
        :ok

      {:ok, {:error, reason}} ->
        # Device creation failure is non-fatal - agent can still operate
        Logger.warning("Failed to create device for agent #{agent_id}: #{inspect(reason)}")
        :ok

      {:error, :core_unavailable} ->
        # Non-fatal - device will be created on next hello
        Logger.warning("Core unavailable while creating device for agent #{agent_id}")
        :ok
    end
  end

  defp track_connected_agent(agent_id, partition_id, request, source_ip) do
    labels = request_value(request, :labels)

    metadata =
      compact_metadata(%{
        partition: partition_id,
        source_ip: source_ip,
        gateway_id: Config.gateway_id(),
        version: request_value(request, :version),
        hostname: request_value(request, :hostname),
        os: request_value(request, :os),
        arch: request_value(request, :arch),
        deployment_type: label_value(labels, [:deployment_type, "deployment_type"])
      })

    ServiceRadar.AgentTracker.track_agent(agent_id, metadata)
  rescue
    _ -> :ok
  end

  defp device_attrs_from_request(partition_id, request, source_ip) do
    capabilities = if request, do: request.capabilities || [], else: []

    %{
      hostname: if(request, do: request.hostname),
      os: if(request, do: request.os),
      arch: if(request, do: request.arch),
      partition: partition_id,
      source_ip: source_ip,
      capabilities: capabilities
    }
  end

  defp touch_agent_record(_identity, agent_id, partition_id, source_ip, config_source) do
    attrs =
      agent_id
      |> agent_record_attrs(partition_id, nil, source_ip)
      |> maybe_add_config_source(config_source)

    case core_call(AgentGatewaySync, :heartbeat_agent, [agent_id, attrs]) do
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

  defp maybe_add_config_source(attrs, nil), do: attrs

  defp maybe_add_config_source(attrs, config_source),
    do: Map.put(attrs, :config_source, config_source)

  defp agent_record_attrs(agent_id, partition_id, request, source_ip) do
    metadata =
      %{
        gateway_id: Config.gateway_id(),
        partition_id: partition_id,
        domain: Config.domain(),
        source_ip: source_ip
      }
      |> Map.merge(request_metadata(request))
      |> compact_metadata()

    compact_metadata(%{
      uid: agent_id,
      name: request_value(request, :hostname),
      version: request_value(request, :version),
      type_id: 4,
      capabilities: request_capabilities(request),
      host: source_ip,
      metadata: metadata
    })
  end

  defp request_capabilities(request) do
    case request do
      %{capabilities: capabilities} -> normalize_capabilities(capabilities)
      _ -> []
    end
  end

  defp request_metadata(request) do
    labels = request_value(request, :labels)

    base = %{
      hostname: request_value(request, :hostname),
      os: request_value(request, :os),
      arch: request_value(request, :arch),
      labels: labels,
      deployment_type: label_value(labels, [:deployment_type, "deployment_type"])
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

  defp label_value(labels, keys) when is_map(labels) do
    Enum.find_value(List.wrap(keys), fn key ->
      case Map.get(labels, key) do
        nil -> nil
        "" -> nil
        value -> value
      end
    end)
  end

  defp label_value(_labels, _keys), do: nil

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

    case nodes do
      [] ->
        Logger.warning(
          "Core call failed: no core nodes available. Connected nodes: #{inspect(Node.list())}. " <>
            "Calling #{inspect(module)}.#{function}"
        )

        {:error, :core_unavailable}

      _ ->
        rpc_core_nodes(nodes, module, function, args, timeout)
    end
  end

  defp rpc_core_nodes(nodes, module, function, args, timeout) do
    Enum.reduce_while(nodes, {:error, :core_unavailable}, fn node, _acc ->
      case :rpc.call(node, module, function, args, timeout) do
        {:badrpc, reason} ->
          Logger.warning(
            "Core RPC call to #{node} failed: #{inspect(reason)}. " <>
              "Calling #{inspect(module)}.#{function}"
          )

          {:cont, {:error, :core_unavailable}}

        result ->
          {:halt, {:ok, result}}
      end
    end)
  end

  defp core_nodes do
    # IMPORTANT: Exclude Node.self() - gateway has no database access and must
    # never execute database-dependent operations locally. All such operations
    # must be forwarded to core-elx nodes via RPC.
    remote_nodes = Node.list()

    # Prefer nodes with ClusterHealth (core coordinator process), then fall back
    # to the configured core node basename. The basename fallback still avoids
    # selecting gateway/web nodes when the coordinator lock is temporarily absent.
    coordinators = find_nodes_with_process(remote_nodes, ServiceRadar.ClusterHealth)
    core_nodes = if coordinators == [], do: named_core_nodes(remote_nodes), else: coordinators

    if core_nodes == [] and remote_nodes != [] do
      Logger.warning(
        "No core-elx nodes found with ClusterHealth. " <>
          "Config compilation and other DB operations will fail until core is available. " <>
          "Connected nodes: #{inspect(remote_nodes)}"
      )
    end

    core_nodes
  end

  defp find_nodes_with_process(nodes, process_name) do
    Enum.filter(nodes, fn node ->
      case :rpc.call(node, Process, :whereis, [process_name], 5_000) do
        pid when is_pid(pid) ->
          true

        {:badrpc, reason} ->
          Logger.debug(
            "RPC call to #{node} for #{inspect(process_name)} failed: #{inspect(reason)}"
          )

          false

        other ->
          Logger.debug("Process #{inspect(process_name)} not found on #{node}: #{inspect(other)}")
          false
      end
    end)
  end

  defp named_core_nodes(nodes) do
    Enum.filter(nodes, &core_node?/1)
  end

  defp core_node?(node) when is_atom(node) do
    String.starts_with?(Atom.to_string(node), "#{core_node_basename()}@")
  end

  defp core_node?(_node), do: false

  defp core_node_basename do
    System.get_env("CLUSTER_CORE_NODE_BASENAME") ||
      Application.get_env(:serviceradar_agent_gateway, :cluster_core_node_basename, "serviceradar_core")
  end

  # Extract component identity from the gRPC stream's mTLS certificate
  # Returns component_id, partition_id, and component_type.
  # Deployment isolation is handled by infrastructure (NATS credentials, DB search_path).
  defp extract_identity_from_stream(stream) do
    with {:ok, cert_der} <- get_peer_cert(stream),
         {:ok, identity} <- ComponentIdentityResolver.resolve_from_cert(cert_der) do
      identity
    else
      {:error, reason} ->
        Logger.warning("Certificate validation failed: #{inspect(reason)}")
        raise GRPC.RPCError, status: :unauthenticated, message: "invalid client certificate"
    end
  end

  # Get the peer certificate from the gRPC stream
  # Uses the adapter's built-in get_cert function which calls :cowboy_req.cert(req)
  defp get_peer_cert(stream) do
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

  defp get_peer_ip(stream) do
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

  defp normalize_peer({ip, _port}), do: ip_to_string(ip)
  defp normalize_peer(ip) when is_tuple(ip), do: ip_to_string(ip)
  defp normalize_peer(ip) when is_binary(ip), do: ip
  defp normalize_peer(_), do: nil

  defp ip_to_string(ip) do
    ip
    |> :inet.ntoa()
    |> to_string()
  end

  defp handle_config_response({:error, :core_unavailable}, agent_id, config_version) do
    Logger.warning(
      "Core unavailable for config request: agent_id=#{agent_id}, version=#{config_version}"
    )

    unavailable_config_response(config_version)
  end

  defp handle_config_response({:ok, :not_modified}, agent_id, config_version) do
    Logger.debug("Agent config not modified: agent_id=#{agent_id}, version=#{config_version}")

    %Monitoring.AgentConfigResponse{
      not_modified: true,
      config_version: config_version
    }
  end

  defp handle_config_response({:ok, {:ok, config}}, agent_id, _config_version) do
    Logger.info(
      "Sending config to agent: agent_id=#{agent_id}, version=#{config.config_version}, checks=#{length(config.checks)}"
    )

    AgentConfigGenerator.to_proto_response(config)
  end

  defp handle_config_response({:ok, {:error, reason}}, agent_id, _config_version) do
    Logger.warning(
      "Failed to generate config for agent #{agent_id}: #{inspect(reason)}, returning empty config"
    )

    empty_config_response("v0-error")
  end

  defp handle_config_response({:ok, other}, agent_id, _config_version) do
    Logger.warning("Unexpected config response for agent #{agent_id}: #{inspect(other)}")
    empty_config_response("v0-error")
  end

  defp unavailable_config_response(config_version) when config_version != "" do
    %Monitoring.AgentConfigResponse{
      not_modified: true,
      config_version: config_version
    }
  end

  defp unavailable_config_response(_config_version), do: empty_config_response("v0-unavailable")

  defp empty_config_response(version) do
    %Monitoring.AgentConfigResponse{
      not_modified: false,
      config_version: version,
      config_timestamp: System.os_time(:second),
      heartbeat_interval_sec: @default_heartbeat_interval_sec,
      config_poll_interval_sec: 300,
      checks: []
    }
  end

  defp initial_stream_status_state do
    %{
      total_services: 0,
      saw_final?: false,
      stream_agent_id: nil,
      expected_idx: 0,
      pinned_total_chunks: nil,
      registered?: false
    }
  end

  defp handle_status_chunk(chunk, state, identity, peer_ip, stream) do
    agent_id = resolve_stream_agent_id(state.stream_agent_id, chunk.agent_id)
    enforce_component_identity!(identity, agent_id, @agent_gateway_component_types)

    services = normalize_chunk_services(chunk.services)
    total_services = validate_stream_service_total!(state.total_services, length(services))
    total_chunks = require_total_chunks(chunk.total_chunks || 0)
    pinned_total_chunks = pin_total_chunks(state.pinned_total_chunks, total_chunks)
    chunk_index = validate_chunk_index!(chunk.chunk_index || 0, total_chunks, state.expected_idx)

    Logger.debug("Received chunk #{chunk_index + 1}/#{total_chunks} from agent #{agent_id}")

    partition = resolve_partition(identity, chunk.partition)
    ensure_stream_registration(state.registered?, identity, agent_id, partition, chunk, stream)

    metadata = chunk_metadata(agent_id, partition, peer_ip, chunk, chunk_index, total_chunks)
    process_chunk_services(services, metadata)

    next_stream_status_state(
      state,
      agent_id,
      total_services,
      pinned_total_chunks,
      chunk_index,
      chunk
    )
  end

  defp resolve_stream_agent_id(nil, chunk_agent_id), do: required_agent_id(chunk_agent_id)

  defp resolve_stream_agent_id(stream_agent_id, chunk_agent_id) do
    agent_id = required_agent_id(chunk_agent_id)

    if agent_id == stream_agent_id do
      agent_id
    else
      raise GRPC.RPCError, status: :invalid_argument, message: "agent_id changed mid-stream"
    end
  end

  defp normalize_chunk_services(services) do
    services
    |> List.wrap()
    |> Enum.reject(&is_nil/1)
  end

  defp validate_stream_service_total!(current_total, service_count) do
    new_total = current_total + service_count

    if new_total > @max_services_per_request do
      raise GRPC.RPCError,
        status: :resource_exhausted,
        message: "too many service statuses in one stream (max: #{@max_services_per_request})"
    end

    new_total
  end

  defp require_total_chunks(total_chunks) when total_chunks > 0, do: total_chunks

  defp require_total_chunks(_total_chunks) do
    raise GRPC.RPCError, status: :invalid_argument, message: "total_chunks must be > 0"
  end

  defp pin_total_chunks(nil, total_chunks), do: total_chunks
  defp pin_total_chunks(total_chunks, total_chunks), do: total_chunks

  defp pin_total_chunks(_pinned_total_chunks, _total_chunks) do
    raise GRPC.RPCError, status: :invalid_argument, message: "total_chunks changed mid-stream"
  end

  defp validate_chunk_index!(chunk_index, total_chunks, expected_idx) do
    cond do
      chunk_index < 0 or chunk_index >= total_chunks ->
        raise GRPC.RPCError, status: :invalid_argument, message: "invalid chunk_index"

      chunk_index != expected_idx ->
        raise GRPC.RPCError, status: :invalid_argument, message: "unexpected chunk_index"

      true ->
        chunk_index
    end
  end

  defp ensure_stream_registration(false, identity, agent_id, partition, chunk, stream) do
    refresh_agent_heartbeat(identity, agent_id, partition, chunk, stream)
  end

  defp ensure_stream_registration(true, _identity, _agent_id, _partition, _chunk, _stream),
    do: :ok

  defp chunk_metadata(agent_id, partition, peer_ip, chunk, chunk_index, total_chunks) do
    %{
      agent_id: agent_id,
      gateway_id: gateway_id(),
      partition: partition,
      source_ip: peer_ip,
      kv_store_id: chunk.kv_store_id,
      timestamp: System.os_time(:second),
      agent_timestamp: chunk.timestamp,
      chunk_index: chunk_index,
      total_chunks: total_chunks,
      is_final: chunk.is_final
    }
  end

  defp process_chunk_services(services, metadata) do
    Enum.each(services, fn service ->
      try do
        process_service_status(service, metadata)
      rescue
        e in GRPC.RPCError ->
          log_invalid_service_status(metadata, service, e)

        e ->
          Logger.warning(
            "Dropping service status from agent #{metadata.agent_id} due to error: #{Exception.message(e)}"
          )
      end
    end)
  end

  defp next_stream_status_state(
         state,
         agent_id,
         total_services,
         pinned_total_chunks,
         chunk_index,
         chunk
       ) do
    if chunk.is_final do
      validate_final_chunk!(chunk_index, pinned_total_chunks)
      record_push_metrics(agent_id, total_services)
      reconcile_agent_release(agent_id)

      {:halt,
       %{
         state
         | total_services: total_services,
           saw_final?: true,
           stream_agent_id: agent_id,
           expected_idx: chunk_index + 1,
           pinned_total_chunks: pinned_total_chunks,
           registered?: true
       }}
    else
      {:cont,
       %{
         state
         | total_services: total_services,
           stream_agent_id: agent_id,
           expected_idx: chunk_index + 1,
           pinned_total_chunks: pinned_total_chunks,
           registered?: true
       }}
    end
  end

  defp validate_final_chunk!(chunk_index, total_chunks) when chunk_index == total_chunks - 1,
    do: :ok

  defp validate_final_chunk!(_chunk_index, _total_chunks) do
    raise GRPC.RPCError,
      status: :invalid_argument,
      message: "final chunk_index does not match total_chunks"
  end

  defp handle_control_stream_message(message, {:awaiting_hello, nil}, identity, stream) do
    case message.payload do
      {:hello, %Monitoring.ControlStreamHello{} = hello} ->
        {:cont, {:ready, initialize_control_session(hello, identity, stream)}}

      _ ->
        raise GRPC.RPCError,
          status: :failed_precondition,
          message: "control stream requires hello as the first message"
    end
  end

  defp handle_control_stream_message(message, {:ready, session}, _identity, _stream) do
    ControlStreamSession.handle_message(session, message)
    {:cont, {:ready, session}}
  end

  defp initialize_control_session(hello, identity, stream) do
    agent_id = required_agent_id(hello.agent_id)
    {identity, _component_type} = resolve_component_type!(identity, agent_id)
    enforce_component_identity!(identity, agent_id, @agent_gateway_component_types)

    partition_id = resolve_partition(identity, hello.partition)
    capabilities = normalize_capabilities(hello.capabilities || [])
    source_ip = get_peer_ip(stream)

    ensure_agent_record(identity, agent_id, partition_id, hello, source_ip)
    ensure_device_for_agent(identity, agent_id, partition_id, hello, source_ip)
    ensure_agent_registered(identity, agent_id, partition_id, capabilities, stream)
    track_connected_agent(agent_id, partition_id, hello, source_ip)

    {:ok, session} = ControlStreamSession.start_link(stream: stream)
    register_control_session(session, agent_id, partition_id, capabilities)
  end

  defp register_control_session(session, agent_id, partition_id, capabilities) do
    case ControlStreamSession.register(session, agent_id, partition_id, capabilities) do
      :ok ->
        Logger.info("Control stream established: agent_id=#{agent_id}, partition=#{partition_id}")
        reconcile_agent_release(agent_id)

        session

      {:error, reason} ->
        Logger.warning(
          "Failed to register control stream for agent #{agent_id}: #{inspect(reason)}"
        )

        raise GRPC.RPCError,
          status: :internal,
          message: "control stream registration failed"
    end
  end

  defp control_session_pid({:ready, session}), do: session
  defp control_session_pid({:awaiting_hello, _}), do: nil

  defp reconcile_agent_release(agent_id) do
    _ = core_call(AgentGatewaySync, :reconcile_agent_release, [agent_id], 15_000)
    :ok
  end
end
