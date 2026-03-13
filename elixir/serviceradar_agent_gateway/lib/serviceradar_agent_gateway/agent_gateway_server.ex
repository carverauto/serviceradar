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

  require Logger

  alias ServiceRadar.Edge.AgentGatewaySync
  alias ServiceRadarAgentGateway.ComponentIdentityResolver

  alias ServiceRadarAgentGateway.{
    AgentRegistryProxy,
    Config,
    ControlStreamSession,
    StatusProcessor
  }

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
    node() |> Atom.to_string()
  end

  @doc """
  Handle an agent hello/enrollment request.

  Called by the agent on startup to announce itself and register with the gateway.
  Validates the mTLS certificate, extracts component identity, and registers the agent.
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

    # Extract identity from mTLS certificate (secure source of truth)
    identity = extract_identity_from_stream(stream)
    {identity, _component_type} = resolve_component_type!(identity, agent_id)
    enforce_component_identity!(identity, agent_id, @agent_gateway_component_types)
    partition_id = resolve_partition(identity, request.partition)
    capabilities = normalize_capabilities(request.capabilities || [])

    ensure_agent_record(identity, agent_id, partition_id, request, get_peer_ip(stream))
    ensure_device_for_agent(identity, agent_id, partition_id, request, get_peer_ip(stream))
    ensure_agent_registered(identity, agent_id, partition_id, capabilities, stream)

    # Registration is stored in the registry and DB; acceptance remains cert-based.

    # Check if config is outdated (placeholder - always false for now)
    # TODO: Implement config versioning in core-elx
    config_outdated = request.config_version == "" or request.config_version == nil

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

    # Extract identity from mTLS certificate for authorization
    identity = extract_identity_from_stream(stream)
    {identity, component_type} = resolve_component_type!(identity, agent_id)
    enforce_component_identity!(identity, agent_id, @agent_gateway_component_types)

    Logger.info("Config request received: component_type=#{component_type}, agent_id=#{agent_id}")

    # Generate config from database using the config generator
    case core_call(AgentGatewaySync, :get_config_if_changed, [agent_id, config_version], 15_000) do
      {:error, :core_unavailable} ->
        Logger.warning(
          "Core unavailable for config request: agent_id=#{agent_id}, version=#{config_version}"
        )

        if config_version != "" do
          %Monitoring.AgentConfigResponse{
            not_modified: true,
            config_version: config_version
          }
        else
          %Monitoring.AgentConfigResponse{
            not_modified: false,
            config_version: "v0-unavailable",
            config_timestamp: System.os_time(:second),
            heartbeat_interval_sec: @default_heartbeat_interval_sec,
            config_poll_interval_sec: 300,
            checks: []
          }
        end

      {:ok, :not_modified} ->
        Logger.debug("Agent config not modified: agent_id=#{agent_id}, version=#{config_version}")

        %Monitoring.AgentConfigResponse{
          not_modified: true,
          config_version: config_version
        }

      {:ok, {:ok, config}} ->
        Logger.info(
          "Sending config to agent: agent_id=#{agent_id}, version=#{config.config_version}, checks=#{length(config.checks)}"
        )

        ServiceRadar.Edge.AgentConfigGenerator.to_proto_response(config)

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

    {total_services, saw_final?, _stream_agent_id, _expected_idx, _pinned_total_chunks,
     _registered?} =
      Enum.reduce_while(request_stream, {0, false, nil, 0, nil, false}, fn chunk,
                                                                           {acc, _saw_final?,
                                                                            stream_agent_id,
                                                                            expected_idx,
                                                                            pinned_total_chunks,
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
            nil ->
              agent_id

            ^agent_id ->
              agent_id

            _ ->
              raise GRPC.RPCError,
                status: :invalid_argument,
                message: "agent_id changed mid-stream"
          end

        enforce_component_identity!(identity, agent_id, @agent_gateway_component_types)

        services =
          chunk.services
          |> List.wrap()
          |> Enum.reject(&is_nil/1)

        service_count = length(services)
        new_total = acc + service_count

        if new_total > @max_services_per_request do
          raise GRPC.RPCError,
            status: :resource_exhausted,
            message: "too many service statuses in one stream (max: #{@max_services_per_request})"
        end

        chunk_index = chunk.chunk_index || 0
        total_chunks = chunk.total_chunks || 0

        if total_chunks <= 0 do
          raise GRPC.RPCError, status: :invalid_argument, message: "total_chunks must be > 0"
        end

        pinned_total_chunks =
          case pinned_total_chunks do
            nil ->
              total_chunks

            ^total_chunks ->
              total_chunks

            _ ->
              raise GRPC.RPCError,
                status: :invalid_argument,
                message: "total_chunks changed mid-stream"
          end

        if chunk_index < 0 or chunk_index >= total_chunks do
          raise GRPC.RPCError, status: :invalid_argument, message: "invalid chunk_index"
        end

        if chunk_index != expected_idx do
          raise GRPC.RPCError, status: :invalid_argument, message: "unexpected chunk_index"
        end

        Logger.debug("Received chunk #{chunk_index + 1}/#{total_chunks} from agent #{agent_id}")

        partition = resolve_partition(identity, chunk.partition)

        if not registered? do
          refresh_agent_heartbeat(identity, agent_id, partition, chunk, stream)
        end

        # Extract metadata from chunk
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
          is_final: chunk.is_final
        }

        # Process each service status in the chunk
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

        if chunk.is_final do
          if chunk_index != total_chunks - 1 do
            raise GRPC.RPCError,
              status: :invalid_argument,
              message: "final chunk_index does not match total_chunks"
          end

          record_push_metrics(agent_id, new_total)
          {:halt, {new_total, true, stream_agent_id, expected_idx + 1, pinned_total_chunks, true}}
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

  @doc """
  Handle the bidirectional control stream from an agent.
  """
  @spec control_stream(Enumerable.t(), GRPC.Server.Stream.t()) :: :ok
  def control_stream(request_stream, stream) do
    identity = extract_identity_from_stream(stream)

    session_pid =
      Enum.reduce_while(request_stream, {:awaiting_hello, nil}, fn message, state ->
        case state do
          {:awaiting_hello, nil} ->
            case message.payload do
              {:hello, %Monitoring.ControlStreamHello{} = hello} ->
                agent_id =
                  case hello.agent_id do
                    nil -> ""
                    value -> value |> to_string() |> String.trim()
                  end

                if agent_id == "" do
                  raise GRPC.RPCError,
                    status: :invalid_argument,
                    message: "agent_id is required"
                end

                {identity, _component_type} = resolve_component_type!(identity, agent_id)
                enforce_component_identity!(identity, agent_id, @agent_gateway_component_types)

                partition_id = resolve_partition(identity, hello.partition)
                capabilities = normalize_capabilities(hello.capabilities || [])

                {:ok, session} = ControlStreamSession.start_link(stream: stream)

                case ControlStreamSession.register(session, agent_id, partition_id, capabilities) do
                  :ok ->
                    Logger.info(
                      "Control stream established: agent_id=#{agent_id}, partition=#{partition_id}"
                    )

                    {:cont, {:ready, session}}

                  {:error, reason} ->
                    Logger.warning(
                      "Failed to register control stream for agent #{agent_id}: #{inspect(reason)}"
                    )

                    raise GRPC.RPCError,
                      status: :internal,
                      message: "control stream registration failed"
                end

              _ ->
                raise GRPC.RPCError,
                  status: :failed_precondition,
                  message: "control stream requires hello as the first message"
            end

          {:ready, session} ->
            ControlStreamSession.handle_message(session, message)
            {:cont, {:ready, session}}
        end
      end)
      |> case do
        {:ready, session} -> session
        {:awaiting_hello, _} -> nil
      end

    if is_pid(session_pid) do
      GenServer.stop(session_pid, :normal)
    end

    :ok
  end

  # Process a single service status and forward to the core
  defp process_service_status(service, metadata) do
    # Validation is done by mTLS certificate verification and deployment isolation.

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
        raise GRPC.RPCError,
          status: :invalid_argument,
          message: "service_name contains invalid characters"

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
      agent_timestamp: metadata.agent_timestamp,
      chunk_index: Map.get(metadata, :chunk_index, 0),
      total_chunks: Map.get(metadata, :total_chunks, 1),
      is_final: Map.get(metadata, :is_final, true)
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
        _ -> @max_status_message_bytes
      end

    if byte_size(msg) > max_bytes do
      if source in ["results", "sysmon-metrics", "snmp-metrics"] do
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

  defp resolve_partition(identity, request_partition) do
    identity_partition =
      case identity do
        %{partition_id: partition_id} -> partition_id
        _ -> nil
      end

    normalize_partition(identity_partition || request_partition)
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
      case identity do
        %{component_id: value} when is_binary(value) -> String.trim(value)
        _ -> ""
      end

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

    config_source = extract_config_source(request)

    touch_agent_record(identity, agent_id, partition_id, source_ip, config_source)
  end

  defp extract_config_source(request) do
    case request do
      %{config_source: source} when is_binary(source) and source != "" ->
        case source do
          "remote" -> :remote
          "local" -> :local
          "cached" -> :cached
          "unassigned" -> :unassigned
          "default" -> :unassigned
          _ -> nil
        end

      _ ->
        nil
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

  defp device_attrs_from_request(partition_id, request, source_ip) do
    capabilities = if request, do: request.capabilities || [], else: []

    %{
      hostname: if(request, do: request.hostname, else: nil),
      os: if(request, do: request.os, else: nil),
      arch: if(request, do: request.arch, else: nil),
      partition: partition_id,
      source_ip: source_ip,
      capabilities: capabilities
    }
  end

  defp touch_agent_record(_identity, agent_id, partition_id, source_ip, config_source) do
    attrs =
      agent_record_attrs(agent_id, partition_id, nil, source_ip)
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

    %{
      uid: agent_id,
      name: request_value(request, :hostname),
      version: request_value(request, :version),
      type_id: 4,
      capabilities: request_capabilities(request),
      host: source_ip,
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
      Logger.warning(
        "Core call failed: no core nodes available. Connected nodes: #{inspect(Node.list())}. " <>
          "Calling #{inspect(module)}.#{function}"
      )

      {:error, :core_unavailable}
    else
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
  end

  defp core_nodes do
    # IMPORTANT: Exclude Node.self() - gateway has no database access and must
    # never execute database-dependent operations locally. All such operations
    # must be forwarded to core-elx nodes via RPC.
    remote_nodes = Node.list()

    # Only look for nodes with ClusterHealth (core coordinator process).
    # We do NOT fall back to Repo-based detection because the gateway should
    # never be selected as a core node target.
    coordinators = find_nodes_with_process(remote_nodes, ServiceRadar.ClusterHealth)

    if coordinators == [] and remote_nodes != [] do
      Logger.warning(
        "No core-elx nodes found with ClusterHealth. " <>
          "Config compilation and other DB operations will fail until core is available.",
        connected_nodes: remote_nodes
      )
    end

    coordinators
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
