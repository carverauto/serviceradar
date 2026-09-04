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

  The server is started automatically by the application supervisor. Incoming
  status updates are processed by `StatusProcessor`, which publishes
  gateway-owned ingress streams locally or forwards statuses to the core
  cluster.
  """

  use GRPC.Server, service: Monitoring.AgentGatewayService.Service

  alias Serviceradar.Agent.Netprobe.V1.FlowAttributionEventBatch
  alias ServiceRadar.Automation.Ansible.SafeFailureEvidence
  alias ServiceRadar.Edge.AgentConfigGenerator
  alias ServiceRadar.Edge.AgentGatewaySync
  alias ServiceRadarAgentGateway.AgentRegistryProxy
  alias ServiceRadarAgentGateway.ComponentIdentityResolver
  alias ServiceRadarAgentGateway.Config
  alias ServiceRadarAgentGateway.ConfigResponse
  alias ServiceRadarAgentGateway.ControlStreamSession
  alias ServiceRadarAgentGateway.StatusProcessor

  require Logger

  # Default heartbeat interval for agents
  @default_heartbeat_interval_sec 30

  # Maximum services per push request to prevent resource exhaustion
  @max_services_per_request 5_000
  @max_stream_status_chunks 5_000
  @max_retained_plugin_status_chunks 10
  @max_status_message_bytes 4_096
  @max_results_message_bytes 15 * 1024 * 1024
  @max_sysmon_message_bytes 15 * 1024 * 1024
  @max_workload_identity_message_bytes 15 * 1024 * 1024
  # Keep this source contract aligned with the core ingestion lane. Rejecting
  # above the producer's 6 MiB limit at the gateway gives the agent a terminal,
  # bounded payload_too_large result instead of an endlessly retryable NACK.
  @max_flow_attribution_message_bytes 6 * 1024 * 1024
  # OTLP relay statuses carry one ready-to-publish OTLP protobuf chunk each
  # (chunked at the edge to <=900 KiB, 1 record = 1 NATS message). Like the
  # other protobuf payloads they must never be truncated, so they share the
  # large strict cap.
  @max_otlp_relay_message_bytes 15 * 1024 * 1024
  @max_stream_status_chunk_bytes 16 * 1024 * 1024
  @max_stream_status_window_bytes 64 * 1024 * 1024
  @max_config_chunk_payload_bytes 1 * 1024 * 1024
  @max_stream_config_chunk_bytes 2 * 1024 * 1024
  @max_stream_config_window_bytes 64 * 1024 * 1024
  @agent_gateway_component_types [:agent]
  @otlp_relay_source "otlp-relay"
  @flow_attribution_source "flow-attribution"
  @plugin_result_source "plugin-result"
  @strict_delivery_sources [@otlp_relay_source, @flow_attribution_source]
  @plugin_result_retained_delivery_capability_v1 "plugin-result-retained:v1"

  @doc false
  @spec gateway_id() :: String.t()
  def gateway_id do
    Config.gateway_id()
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
    partition_id = resolve_partition(identity)
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
    partition_id = resolve_partition(identity)

    Logger.info("Config request received: component_type=#{component_type}, agent_id=#{agent_id}")

    # Generate config from database using the config generator
    AgentGatewaySync
    |> core_call(:get_config_if_changed, [agent_id, partition_id, config_version], 15_000)
    |> handle_config_response(agent_id, config_version)
  end

  @doc """
  Resolve a scoped credential broker grant for an authenticated agent.

  The agent receives credential material only after the gateway validates the
  caller's mTLS identity and core validates the persisted grant scope. Plugins
  continue to see only grant envelopes.
  """
  @spec resolve_credential_grant(
          Monitoring.CredentialBrokerResolveRequest.t(),
          GRPC.Server.Stream.t()
        ) :: Monitoring.CredentialBrokerResolveResponse.t()
  def resolve_credential_grant(request, stream) do
    agent_id = required_agent_id(request.agent_id)
    identity = extract_identity_from_stream(stream)
    {identity, _component_type} = resolve_component_type!(identity, agent_id)
    enforce_component_identity!(identity, agent_id, @agent_gateway_component_types)

    request_map = %{
      agent_id: agent_id,
      grant_id: request.grant_id,
      credential_secret_ref: request.credential_secret_ref,
      consumer_kind: request.consumer_kind,
      consumer_id: request.consumer_id,
      purpose: request.purpose,
      resolution_location: request.resolution_location
    }

    AgentGatewaySync
    |> core_call(:resolve_credential_broker_grant, [request_map], 15_000)
    |> credential_grant_response(agent_id, request.grant_id)
  end

  @doc false
  def credential_grant_response(core_result, agent_id, grant_id) do
    case core_result do
      {:ok, {:ok, material}} ->
        %Monitoring.CredentialBrokerResolveResponse{
          success: true,
          message: "credential grant resolved",
          value: Map.get(material, :value, ""),
          fields: Map.get(material, :fields, %{}),
          source_type: Map.get(material, :source_type, ""),
          lease_expires_at_unix: Map.get(material, :lease_expires_at_unix, 0),
          cache_status: Map.get(material, :cache_status, "")
        }

      {:ok, {:error, reason}} ->
        credential_grant_denied_response(agent_id, grant_id, reason)

      {:error, reason} ->
        credential_grant_denied_response(agent_id, grant_id, reason)
    end
  end

  defp credential_grant_denied_response(agent_id, grant_id, reason) do
    Logger.warning(
      "Credential broker grant resolution denied",
      [agent_id: agent_id, grant_id: grant_id] ++ SafeFailureEvidence.log_metadata(reason)
    )

    %Monitoring.CredentialBrokerResolveResponse{
      success: false,
      message: "credential grant resolution denied"
    }
  end

  @doc """
  Resolve a single-use automation launch envelope for an authenticated agent.

  The mTLS certificate, not the request body, establishes the agent identity.
  Only the opaque reference and command correlation cross this RPC boundary.
  """
  @spec resolve_automation_launch_envelope(
          Monitoring.AutomationLaunchEnvelopeResolveRequest.t(),
          GRPC.Server.Stream.t()
        ) :: Monitoring.AutomationLaunchEnvelopeResolveResponse.t()
  def resolve_automation_launch_envelope(request, stream) do
    identity = extract_identity_from_stream(stream)
    agent_id = identity |> Map.fetch!(:component_id) |> required_agent_id()
    {identity, _component_type} = resolve_component_type!(identity, agent_id)
    enforce_component_identity!(identity, agent_id, @agent_gateway_component_types)
    partition_id = resolve_partition(identity)

    enforce_component_identity!(
      identity,
      required_agent_id(request.agent_id),
      @agent_gateway_component_types
    )

    request_map = %{
      agent_id: agent_id,
      partition_id: partition_id,
      envelope_ref: request.envelope_ref,
      command_id: request.command_id
    }

    AgentGatewaySync
    |> core_call(:resolve_automation_launch_envelope, [request_map], 15_000)
    |> automation_launch_envelope_response(agent_id, request.command_id)
  end

  @doc false
  def automation_launch_envelope_response(core_result, agent_id, command_id) do
    case core_result do
      {:ok, {:ok, material}} ->
        %Monitoring.AutomationLaunchEnvelopeResolveResponse{
          success: true,
          message: "automation launch envelope resolved",
          bearer: Map.get(material, :bearer, <<>>),
          idempotency_key: Map.get(material, :idempotency_key, <<>>),
          callback_grant_id: Map.get(material, :callback_grant_id, ""),
          expires_at_unix: expires_at_unix(Map.get(material, :expires_at)),
          callback_url: Map.get(material, :callback_url, <<>>),
          callback_allowed_origin: Map.get(material, :callback_allowed_origin, <<>>),
          manifest_sha256: Map.get(material, :manifest_sha256, <<>>),
          scm_revision: Map.get(material, :scm_revision, <<>>),
          content_sha256: Map.get(material, :content_sha256, <<>>),
          callback_phase: Map.get(material, :callback_phase, <<>>),
          callback_operation: Map.get(material, :callback_operation, <<>>),
          callback_state: Map.get(material, :callback_state, <<>>),
          controller_id: Map.get(material, :controller_id, ""),
          inventory_id: Map.get(material, :inventory_id, 0),
          job_template_id: Map.get(material, :job_template_id, 0),
          callback_credential_type_id: Map.get(material, :callback_credential_type_id, 0),
          callback_credential_organization_id: Map.get(material, :callback_credential_organization_id, 0),
          callback_credential_injector_sha256: Map.get(material, :callback_credential_injector_sha256, <<>>),
          dispatch_agent_id: Map.get(material, :dispatch_agent_id, ""),
          child_execution_id: Map.get(material, :child_execution_id, ""),
          command_id: Map.get(material, :command_id, "")
        }

      {:ok, {:error, reason}} ->
        automation_launch_envelope_denied_response(agent_id, command_id, reason)

      {:error, reason} ->
        automation_launch_envelope_denied_response(agent_id, command_id, reason)
    end
  end

  defp automation_launch_envelope_denied_response(agent_id, command_id, reason) do
    Logger.warning(
      "Automation launch envelope resolution denied",
      [agent_id: agent_id, command_id: command_id] ++ SafeFailureEvidence.log_metadata(reason)
    )

    %Monitoring.AutomationLaunchEnvelopeResolveResponse{
      success: false,
      message: "automation launch envelope resolution denied"
    }
  end

  defp expires_at_unix(%DateTime{} = expires_at), do: DateTime.to_unix(expires_at, :second)
  defp expires_at_unix(_expires_at), do: 0

  @doc """
  Stream an agent config response in bounded chunks.

  The payload chunks contain the protobuf-encoded AgentConfigResponse that unary
  GetConfig would return, preserving existing config semantics while avoiding a
  single oversized gRPC response message.
  """
  @spec stream_config(Monitoring.AgentConfigRequest.t(), GRPC.Server.Stream.t()) :: :ok
  def stream_config(request, stream) do
    agent_id = required_agent_id(request.agent_id)
    config_version = request.config_version || ""

    Logger.debug("Agent streamed config request: agent_id=#{agent_id}, version=#{config_version}")

    identity = extract_identity_from_stream(stream)
    {identity, component_type} = resolve_component_type!(identity, agent_id)
    enforce_component_identity!(identity, agent_id, @agent_gateway_component_types)
    partition_id = resolve_partition(identity)

    Logger.info("Stream config request received: component_type=#{component_type}, agent_id=#{agent_id}")

    response =
      AgentGatewaySync
      |> core_call(:get_config_if_changed, [agent_id, partition_id, config_version], 15_000)
      |> handle_config_response(agent_id, config_version)

    chunks = config_response_chunks(agent_id, response)

    Logger.info(
      "Streaming config to agent: agent_id=#{agent_id}, version=#{response.config_version}, chunks=#{length(chunks)}, bytes=#{config_response_size(response)}"
    )

    send_config_chunks(chunks, stream)
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
        status: :invalid_argument,
        message: "too many service statuses in one request (max: #{@max_services_per_request})"
    end

    # Extract identity from mTLS certificate (secure source of truth)
    identity = extract_identity_from_stream(stream)
    enforce_component_identity!(identity, agent_id, @agent_gateway_component_types)
    partition = resolve_partition(identity)

    refresh_agent_heartbeat(identity, agent_id, partition, request, stream)
    delivery_capabilities = AgentRegistryProxy.delivery_capabilities(partition, agent_id)

    Logger.info("Received status push from agent #{agent_id}: #{service_count} services")

    # Extract metadata from request
    # Use server's gateway_id() instead of client-provided request.gateway_id
    # to prevent spoofing and ensure correct data attribution
    metadata = %{
      agent_id: agent_id,
      gateway_id: gateway_id(),
      partition: partition,
      authenticated_partition: Map.get(identity, :partition_id),
      source_ip: get_peer_ip(stream),
      kv_store_id: request.kv_store_id,
      timestamp: System.os_time(:second),
      agent_timestamp: request.timestamp,
      delivery_capabilities: delivery_capabilities
    }

    valid_services = Enum.filter(services, &match?(%Monitoring.GatewayServiceStatus{}, &1))
    {processed_count, response} = process_status_services_with_count(valid_services, metadata)

    if processed_count == 0 and service_count > 0 do
      raise GRPC.RPCError, status: :invalid_argument, message: "no valid service statuses"
    end

    # Record metrics
    record_push_metrics(agent_id, processed_count)
    reconcile_agent_release(agent_id)

    response
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

    response = process_status_stream(Enum.reverse(state.status_chunks))
    record_push_metrics(state.stream_agent_id, state.total_services)
    reconcile_agent_release(state.stream_agent_id)
    response
  end

  @doc """
  Handle the bidirectional control stream from an agent.
  """
  @spec control_stream(Enumerable.t(), GRPC.Server.Stream.t()) :: :ok
  def control_stream(request_stream, stream) do
    identity_context = extract_identity_context_from_stream(stream)

    session_pid =
      request_stream
      |> Enum.reduce_while({:awaiting_hello, nil}, fn message, state ->
        handle_control_stream_message(message, state, identity_context, stream)
      end)
      |> control_session_pid()

    if is_pid(session_pid) do
      GenServer.stop(session_pid, :normal)
    end

    :ok
  end

  @doc false
  def process_status_services(services, metadata) when is_list(services) and is_map(metadata) do
    {_count, response} = process_status_services_with_count(services, metadata)
    response
  end

  defp process_status_services_with_count(services, metadata) do
    validate_unary_agent_retained_isolation!(services, metadata)

    {processed_count, directives, outcome} =
      Enum.reduce(services, {0, [], :best_effort_accepted}, fn service, acc ->
        process_push_service(service, metadata, acc)
      end)

    {processed_count, delivery_response(outcome, directives)}
  end

  # Invalid agent-retained payloads fail the RPC. A valid downstream non-commit
  # is an ordinary negative acknowledgement and never enters StatusBuffer.
  defp process_push_service(service, metadata, {count, directives, outcome}) do
    if strict_delivery_service?(service, metadata) do
      {service_outcome, service_directives} = process_service_status(service, metadata)

      {
        count + 1,
        directives ++ service_directives,
        combine_delivery_outcomes(outcome, service_outcome)
      }
    else
      try do
        {service_outcome, service_directives} = process_service_status(service, metadata)

        {
          count + 1,
          directives ++ service_directives,
          combine_delivery_outcomes(outcome, service_outcome)
        }
      rescue
        e in GRPC.RPCError ->
          log_invalid_service_status(metadata, service, e)

          {count, directives, outcome}

        e ->
          Logger.warning("Dropping service status from agent #{metadata.agent_id} due to error: #{Exception.message(e)}")

          {count, directives, outcome}
      end
    end
  end

  defp validate_unary_agent_retained_isolation!(services, metadata) do
    if Enum.any?(services, &agent_retained_service?(&1, metadata)) and length(services) != 1 do
      raise GRPC.RPCError,
        status: :invalid_argument,
        message: "agent-retained status must be isolated in exactly one service"
    end
  end

  defp strict_delivery_service?(%Monitoring.GatewayServiceStatus{source: source}, metadata) when is_binary(source),
    do: strict_delivery_source?(String.trim(source), metadata)

  defp strict_delivery_service?(_service, _metadata), do: false

  defp strict_delivery_source?(source, _metadata) when source in @strict_delivery_sources, do: true

  defp strict_delivery_source?(@plugin_result_source, metadata), do: retained_plugin_result_delivery?(metadata)

  defp strict_delivery_source?(_source, _metadata), do: false

  defp retained_plugin_result_delivery?(metadata) do
    @plugin_result_retained_delivery_capability_v1 in List.wrap(Map.get(metadata, :delivery_capabilities, []))
  end

  defp agent_retained_service?(%Monitoring.GatewayServiceStatus{source: source}, metadata) do
    source = normalize_service_field(source)

    source == @flow_attribution_source or
      (source == @plugin_result_source and retained_plugin_result_delivery?(metadata))
  end

  defp agent_retained_service?(_service, _metadata), do: false

  # Process a single service status and forward to the core
  defp process_service_status(service, metadata) do
    {service, status} = prepare_service_status(service, metadata)
    deliver_prepared_service_status(service, status)
  end

  defp prepare_service_status(service, metadata) do
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

    validate_agent_retained_payload!(status)
    log_package_telemetry_status(status)
    {service, status}
  end

  defp log_package_telemetry_status(%{source: source} = status) when is_binary(source) do
    if String.starts_with?(source, ["addon:", "plugin:"]) do
      Logger.info(
        "Forwarding package telemetry status: agent=#{status.agent_id} source=#{source} " <>
          "service_type=#{status.service_type} service=#{status.service_name} " <>
          "message_bytes=#{message_size(status.message)}"
      )
    end
  end

  defp log_package_telemetry_status(_status), do: :ok

  defp canonical_partition(partition) when is_binary(partition) do
    trimmed = String.trim(partition)

    if trimmed == partition and byte_size(partition) > 0 and byte_size(partition) <= 128 and
         not String.contains?(partition, ["\n", "\r", "\t"]) do
      partition
    end
  end

  defp canonical_partition(_partition), do: nil

  defp normalize_partition(partition) when is_binary(partition) do
    partition |> String.trim() |> canonical_partition() || "default"
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
      partition: status_partition(service, metadata, source),
      authenticated_partition: canonical_partition(Map.get(metadata, :authenticated_partition)),
      source: source,
      kv_store_id: service.kv_store_id || metadata.kv_store_id,
      timestamp: metadata.timestamp,
      agent_timestamp: metadata.agent_timestamp,
      request_id: Logger.metadata()[:request_id],
      chunk_index: Map.get(metadata, :chunk_index, 0),
      total_chunks: Map.get(metadata, :total_chunks, 1),
      is_final: Map.get(metadata, :is_final, true),
      delivery_capabilities: Map.get(metadata, :delivery_capabilities, [])
    }
  end

  # Source routing keeps its existing partition semantics. Authority checks use
  # the separate authenticated_partition stamped from the raw mTLS identity.
  defp status_partition(service, metadata, source) do
    if mtls_partition_source?(source, metadata) do
      normalize_partition(metadata.partition)
    else
      normalize_partition(service.partition || metadata.partition)
    end
  end

  # Which sources have their partition forced from the certificate.
  #
  # Deliberately a SUPERSET of strict_delivery_source?/2 rather than an addition
  # to @strict_delivery_sources, because that list does a second, unrelated
  # thing: a strict-delivery status bypasses the lenient rescue, so any
  # exception raised while handling it aborts the whole chunk instead of being
  # swallowed. Adding "addon:" there would change failure semantics for
  # otel-collector, powerdns, anomaly-addon and bumblebee at the same time --
  # which is a fleet-wide blast radius for what is meant to be a stamping fix.
  #
  # Native add-on telemetry becomes durable inventory and OCSF events, so the
  # partition it lands under must be the authenticated one and not a value the
  # add-on supplied. `plugin:` (the wasm package-telemetry prefix) is left alone
  # here on purpose: wasm inventory writes arrive as the separate
  # `plugin-result` source, which already has its own conditional strict
  # handling.
  defp mtls_partition_source?(source, metadata) do
    strict_delivery_source?(source, metadata) or addon_telemetry_source?(source)
  end

  defp addon_telemetry_source?("addon:" <> _addon_id), do: true
  defp addon_telemetry_source?(_source), do: false

  defp normalize_service_message(nil, source), do: normalize_message("", source)

  defp normalize_service_message(message, source) when is_binary(message), do: normalize_message(message, source)

  defp normalize_service_message(message, source) when is_list(message),
    do: message |> IO.iodata_to_binary() |> normalize_message(source)

  defp normalize_service_message(_, source), do: normalize_message("", source)

  defp normalize_response_time(rt) when is_integer(rt) and rt >= 0 and rt <= 86_400_000, do: rt
  defp normalize_response_time(rt) when is_integer(rt) and rt > 86_400_000, do: 86_400_000
  defp normalize_response_time(_), do: 0

  @doc false
  def forward_service_status(service, status) do
    {_outcome, directives} = deliver_prepared_service_status(service, status)
    directives
  end

  defp deliver_prepared_service_status(service, status) do
    case StatusProcessor.process(status) do
      :ok ->
        {committed_delivery_outcome(status), []}

      {:ok, result} ->
        {committed_delivery_outcome(status), gateway_status_directives(service, result)}

      {:error, reason} ->
        if committed_plugin_result_error?(status, reason) do
          # Plugin-result ingestion persists the raw result and its handler
          # failure before returning this error. Retrying it forever cannot
          # improve durability and would block every later result in the
          # agent's retained batch.
          {:agent_retained_committed, []}
        else
          handle_delivery_error(service, status, reason)
        end
    end
  end

  defp committed_delivery_outcome(status) do
    if agent_retained_status?(status), do: :agent_retained_committed, else: :best_effort_accepted
  end

  defp handle_delivery_error(service, status, reason) do
    cond do
      agent_retained_status?(status) ->
        Logger.warning("Failed to commit #{status.source} status from agent #{status.agent_id}: #{inspect(reason)}")
        {:agent_retained_uncommitted, []}

      strict_delivery_status?(status) ->
        maybe_raise_strict_delivery_error(service, status, reason)

      true ->
        Logger.warning("Failed to process status for service #{service.service_name}: #{inspect(reason)}")
        {:best_effort_accepted, []}
    end
  end

  defp agent_retained_status?(%{source: @flow_attribution_source}), do: true

  defp agent_retained_status?(%{source: @plugin_result_source} = status), do: retained_plugin_result_delivery?(status)

  defp agent_retained_status?(_status), do: false

  defp validate_agent_retained_payload!(%{source: @flow_attribution_source, message: message}) do
    case FlowAttributionEventBatch.decode(message) do
      %FlowAttributionEventBatch{} -> :ok
      {:ok, %FlowAttributionEventBatch{}} -> :ok
      _other -> invalid_retained_payload!("flow-attribution")
    end
  rescue
    _error -> invalid_retained_payload!("flow-attribution")
  end

  defp validate_agent_retained_payload!(%{source: @plugin_result_source} = status) do
    if retained_plugin_result_delivery?(status) do
      validate_retained_plugin_payload!(status.message)
    end
  end

  defp validate_agent_retained_payload!(_status), do: :ok

  defp validate_retained_plugin_payload!(message) do
    case Jason.decode(message) do
      {:ok, %{"status" => plugin_status, "summary" => summary}}
      when is_binary(plugin_status) and is_binary(summary) ->
        validate_retained_plugin_fields!(plugin_status, summary)

      _other ->
        invalid_retained_payload!("plugin-result")
    end
  end

  defp validate_retained_plugin_fields!(plugin_status, summary) do
    normalized_status = plugin_status |> String.trim() |> String.upcase()

    valid_status? =
      plugin_status == normalized_status and
        normalized_status in ["OK", "WARNING", "CRITICAL", "UNKNOWN"]

    if valid_status? and String.trim(summary) != "" do
      :ok
    else
      invalid_retained_payload!("plugin-result")
    end
  end

  defp invalid_retained_payload!(source) do
    raise GRPC.RPCError,
      status: :invalid_argument,
      message: "invalid #{source} payload"
  end

  defp delivery_response(:agent_retained_uncommitted, _directives) do
    %Monitoring.GatewayStatusResponse{received: false, directives: []}
  end

  defp delivery_response(_outcome, directives) do
    %Monitoring.GatewayStatusResponse{received: true, directives: directives}
  end

  defp combine_delivery_outcomes(:agent_retained_uncommitted, _outcome), do: :agent_retained_uncommitted
  defp combine_delivery_outcomes(_outcome, :agent_retained_uncommitted), do: :agent_retained_uncommitted
  defp combine_delivery_outcomes(:agent_retained_committed, _outcome), do: :agent_retained_committed
  defp combine_delivery_outcomes(_outcome, :agent_retained_committed), do: :agent_retained_committed
  defp combine_delivery_outcomes(_left, _right), do: :best_effort_accepted

  defp committed_plugin_result_error?(
         %{source: @plugin_result_source} = status,
         {:plugin_result_handlers_failed, _failures}
       ), do: strict_delivery_status?(status)

  defp committed_plugin_result_error?(_status, _reason), do: false

  defp maybe_raise_strict_delivery_error(service, status, reason) do
    if strict_delivery_status?(status) do
      # Bufferable downstream errors are acknowledged by StatusProcessor. An
      # error reaching here is not queueable and must preserve strict delivery.
      Logger.warning("Failed to forward #{status.source} status from agent #{status.agent_id}: #{inspect(reason)}")

      raise GRPC.RPCError,
        status: :unavailable,
        message: "#{status.source} forward failed"
    else
      Logger.warning("Failed to process status for service #{service.service_name}: #{inspect(reason)}")

      []
    end
  end

  defp strict_delivery_status?(%{source: source} = status), do: strict_delivery_source?(source, status)

  defp strict_delivery_status?(_status), do: false

  defp gateway_status_directives(service, %{directives: directives}) when is_map(directives) do
    Enum.flat_map(directives, fn {target, payload} ->
      build_gateway_status_directive(service, target, payload)
    end)
  end

  defp gateway_status_directives(_service, _result), do: []

  defp build_gateway_status_directive(service, target, payload) when is_map(payload) and map_size(payload) > 0 do
    case Jason.encode(payload) do
      {:ok, payload_json} ->
        [
          %Monitoring.GatewayStatusDirective{
            service_name: service.service_name || to_string(target),
            service_type: service.service_type || "",
            directive_type: gateway_status_directive_type(target, payload),
            payload_json: payload_json
          }
        ]

      {:error, reason} ->
        Logger.warning("Dropping unencodable gateway status directive: #{inspect(reason)}")
        []
    end
  end

  defp build_gateway_status_directive(_service, _target, _payload), do: []

  defp gateway_status_directive_type(target, %{"reconcile_floor" => true}) do
    "#{target}.reconcile_floor"
  end

  defp gateway_status_directive_type(target, _payload), do: "#{target}.ack"

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
    max_bytes = max_message_bytes(source)

    if byte_size(msg) > max_bytes do
      if strict_message_size_source?(source) do
        raise GRPC.RPCError,
          status: :resource_exhausted,
          message: "payload_too_large: payload exceeds max size"
      else
        binary_part(msg, 0, @max_status_message_bytes)
      end
    else
      msg
    end
  end

  defp max_message_bytes("results"), do: @max_results_message_bytes
  defp max_message_bytes("sysmon-metrics"), do: @max_sysmon_message_bytes
  defp max_message_bytes("snmp-metrics"), do: @max_results_message_bytes
  defp max_message_bytes("icmp-metrics"), do: @max_results_message_bytes
  defp max_message_bytes("rperf-metrics"), do: @max_results_message_bytes
  defp max_message_bytes("mtr-metrics"), do: @max_results_message_bytes
  defp max_message_bytes("sweep-metrics"), do: @max_results_message_bytes
  defp max_message_bytes("plugin-result"), do: @max_results_message_bytes
  defp max_message_bytes("workload-identity"), do: @max_workload_identity_message_bytes
  defp max_message_bytes("flow-attribution"), do: @max_flow_attribution_message_bytes
  defp max_message_bytes(@otlp_relay_source), do: @max_otlp_relay_message_bytes
  defp max_message_bytes("addon:" <> _addon_id), do: @max_flow_attribution_message_bytes
  defp max_message_bytes("plugin:" <> _plugin_id), do: @max_flow_attribution_message_bytes
  defp max_message_bytes(_source), do: @max_status_message_bytes

  defp strict_message_size_source?("addon:" <> _addon_id), do: true
  defp strict_message_size_source?("plugin:" <> _plugin_id), do: true

  defp strict_message_size_source?(source) do
    source in [
      "results",
      "sysmon-metrics",
      "snmp-metrics",
      "icmp-metrics",
      "rperf-metrics",
      "mtr-metrics",
      "sweep-metrics",
      "plugin-result",
      "workload-identity",
      "flow-attribution",
      @otlp_relay_source
    ]
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

  defp resolve_partition(identity) do
    partition_id = Map.fetch!(identity, :partition_id)
    normalize_partition(partition_id)
  end

  defp resolve_component_type!(identity, component_id) do
    case Map.get(identity, :component_type) do
      nil ->
        Logger.warning("Component type missing from client certificate: component_id=#{component_id}")

        raise GRPC.RPCError, status: :permission_denied, message: "component_type missing"

      component_type when is_atom(component_type) ->
        {identity, component_type}

      _ ->
        Logger.warning("Invalid component type in client certificate: component_id=#{component_id}")

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
      Logger.warning("Component identity mismatch: request=#{component_id} cert=#{cert_component_id}")

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

    metadata = compact_metadata(metadata)

    # nil means a heartbeat that cannot renegotiate capabilities. An explicit
    # list comes from authenticated hello and must also be able to clear a
    # previously negotiated capability set.
    if is_list(capabilities), do: Map.put(metadata, :capabilities, capabilities), else: metadata
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

    # Prefer the agent's self-reported host IP when present so DIRE links to the
    # real device. The TCP peer IP (source_ip) is wrong for NAT'd/external agents.
    device_ip = request_value(request, :host_ip) || source_ip

    %{
      hostname: if(request, do: request.hostname),
      os: if(request, do: request.os),
      arch: if(request, do: request.arch),
      partition: partition_id,
      source_ip: device_ip,
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

  defp maybe_add_config_source(attrs, config_source), do: Map.put(attrs, :config_source, config_source)

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
      gateway_id: Config.gateway_id(),
      capabilities: request_capabilities(request),
      host: request_value(request, :hostname),
      ip: source_ip,
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
          Logger.debug("RPC call to #{node} for #{inspect(process_name)} failed: #{inspect(reason)}")

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
      Application.get_env(
        :serviceradar_agent_gateway,
        :cluster_core_node_basename,
        "serviceradar_core"
      )
  end

  # Extract component identity from the gRPC stream's mTLS certificate
  # Returns component_id, partition_id, and component_type.
  # Deployment isolation is handled by infrastructure (NATS credentials, DB search_path).
  defp extract_identity_from_stream(stream) do
    stream
    |> extract_identity_context_from_stream()
    |> Map.fetch!(:identity)
  end

  defp extract_identity_context_from_stream(stream) do
    with {:ok, cert_der} <- get_peer_cert(stream),
         {:ok, identity} <- ComponentIdentityResolver.resolve_from_cert(cert_der) do
      %{
        identity: identity,
        component_id: Map.get(identity, :component_id),
        partition_id: Map.get(identity, :partition_id),
        component_type: Map.get(identity, :component_type),
        cert_fingerprint_sha256: cert_fingerprint_sha256(cert_der)
      }
    else
      {:error, reason} ->
        Logger.warning("Certificate validation failed: #{inspect(reason)}")
        raise GRPC.RPCError, status: :unauthenticated, message: "invalid client certificate"
    end
  end

  defp cert_fingerprint_sha256(cert_der) do
    cert_der
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
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

  defp handle_config_response(core_result, agent_id, config_version) do
    ConfigResponse.from_core_result(core_result, agent_id, config_version, fn config ->
      summary = config_payload_summary(config)

      Logger.info(
        "Sending config to agent: agent_id=#{agent_id}, version=#{config.config_version}, checks=#{length(config.checks)}, " <>
          "config_json_bytes=#{summary.config_json_bytes}, mapper_jobs=#{summary.mapper_jobs}, plugins=#{summary.plugins}"
      )

      AgentConfigGenerator.to_proto_response(config)
    end)
  end

  defp config_payload_summary(config) do
    config_json = Map.get(config, :config_json) || ""
    decoded = decode_config_json(config_json)
    mapper = Map.get(decoded, "mapper")
    plugins = Map.get(decoded, "plugins")

    %{
      config_json_bytes: byte_size(config_json),
      mapper_jobs: mapper_scheduled_job_count(mapper),
      plugins: plugin_assignment_count(plugins)
    }
  end

  defp decode_config_json(config_json) when is_binary(config_json) and config_json != "" do
    case Jason.decode(config_json) do
      {:ok, %{} = decoded} -> decoded
      _ -> %{}
    end
  end

  defp decode_config_json(_config_json), do: %{}

  defp mapper_scheduled_job_count(%{"scheduled_jobs" => jobs}) when is_list(jobs), do: length(jobs)

  defp mapper_scheduled_job_count(_mapper), do: 0

  defp plugin_assignment_count(%{"assignments" => assignments}) when is_list(assignments), do: length(assignments)

  defp plugin_assignment_count(_plugins), do: 0

  defp initial_stream_status_state do
    %{
      total_services: 0,
      saw_final?: false,
      stream_agent_id: nil,
      expected_idx: 0,
      pinned_total_chunks: nil,
      pinned_delivery_capabilities: nil,
      registered?: false,
      stream_bytes: 0,
      status_chunks: []
    }
  end

  defp handle_status_chunk(chunk, state, identity, peer_ip, stream) do
    if state.saw_final? do
      raise GRPC.RPCError,
        status: :invalid_argument,
        message: "stream contains a chunk after the final chunk"
    end

    chunk_bytes = stream_status_chunk_size(chunk)
    stream_bytes = validate_stream_status_byte_window!(state.stream_bytes, chunk_bytes)
    agent_id = resolve_stream_agent_id(state.stream_agent_id, chunk.agent_id)
    enforce_component_identity!(identity, agent_id, @agent_gateway_component_types)

    services = normalize_chunk_services(chunk.services)
    total_services = validate_stream_service_total!(state.total_services, length(services))
    total_chunks = require_total_chunks(chunk.total_chunks || 0)
    pinned_total_chunks = pin_total_chunks(state.pinned_total_chunks, total_chunks)

    pinned_delivery_capabilities =
      pin_stream_capabilities(state.pinned_delivery_capabilities, chunk.capabilities)

    chunk_index = validate_chunk_index!(chunk.chunk_index || 0, total_chunks, state.expected_idx)
    partition = resolve_partition(identity)

    metadata =
      chunk_metadata(
        agent_id,
        partition,
        Map.get(identity, :partition_id),
        peer_ip,
        chunk,
        chunk_index,
        total_chunks,
        pinned_delivery_capabilities
      )

    validate_retained_plugin_chunk_count!(services, metadata, total_chunks)

    Logger.debug("Received chunk #{chunk_index + 1}/#{total_chunks} from agent #{agent_id}")

    ensure_stream_registration(state.registered?, identity, agent_id, partition, chunk, stream)

    next_stream_status_state(state, chunk, %{
      agent_id: agent_id,
      total_services: total_services,
      pinned_total_chunks: pinned_total_chunks,
      pinned_delivery_capabilities: pinned_delivery_capabilities,
      chunk_index: chunk_index,
      stream_bytes: stream_bytes,
      status_chunk: {services, metadata}
    })
  end

  @doc false
  def stream_status_chunk_size(%Monitoring.GatewayStatusChunk{} = chunk) do
    chunk
    |> Protobuf.Encoder.encode_to_iodata()
    |> IO.iodata_length()
  end

  @doc false
  def config_response_chunks(agent_id, %Monitoring.AgentConfigResponse{} = response) do
    payload =
      response
      |> Protobuf.Encoder.encode_to_iodata()
      |> IO.iodata_to_binary()

    validate_stream_config_window!(byte_size(payload))

    payload_sha256 = sha256_hex(payload)
    total_chunks = max(ceil_div(byte_size(payload), @max_config_chunk_payload_bytes), 1)

    Enum.map(0..(total_chunks - 1), fn chunk_index ->
      offset = chunk_index * @max_config_chunk_payload_bytes
      chunk_size = min(@max_config_chunk_payload_bytes, max(byte_size(payload) - offset, 0))

      chunk =
        %Monitoring.AgentConfigChunk{
          agent_id: agent_id,
          config_version: response.config_version,
          config_timestamp: response.config_timestamp,
          not_modified: response.not_modified,
          payload: binary_part(payload, offset, chunk_size),
          is_final: chunk_index == total_chunks - 1,
          chunk_index: chunk_index,
          total_chunks: total_chunks,
          payload_sha256: payload_sha256
        }

      validate_stream_config_chunk!(chunk)
    end)
  end

  @doc false
  def send_config_chunks(chunks, stream) when is_list(chunks) do
    _stream =
      Enum.reduce(chunks, stream, fn %Monitoring.AgentConfigChunk{} = chunk, stream ->
        GRPC.Server.send_reply(stream, chunk)
      end)

    :ok
  end

  @doc false
  def config_response_size(%Monitoring.AgentConfigResponse{} = response) do
    response
    |> Protobuf.Encoder.encode_to_iodata()
    |> IO.iodata_length()
  end

  defp validate_stream_config_window!(payload_bytes) do
    if payload_bytes > @max_stream_config_window_bytes do
      raise GRPC.RPCError,
        status: :resource_exhausted,
        message: "config stream exceeds byte budget"
    end
  end

  defp validate_stream_config_chunk!(%Monitoring.AgentConfigChunk{} = chunk) do
    chunk_bytes =
      chunk
      |> Protobuf.Encoder.encode_to_iodata()
      |> IO.iodata_length()

    if chunk_bytes > @max_stream_config_chunk_bytes do
      raise GRPC.RPCError,
        status: :resource_exhausted,
        message: "config stream chunk exceeds byte budget"
    end

    chunk
  end

  defp ceil_div(0, _divisor), do: 0
  defp ceil_div(value, divisor), do: div(value + divisor - 1, divisor)

  defp sha256_hex(payload) do
    payload
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @doc false
  def validate_stream_status_byte_window!(current_bytes, chunk_bytes)
      when is_integer(current_bytes) and is_integer(chunk_bytes) and chunk_bytes >= 0 do
    cond do
      chunk_bytes > @max_stream_status_chunk_bytes ->
        raise GRPC.RPCError,
          status: :resource_exhausted,
          message: "payload_too_large: stream status chunk exceeds byte budget"

      current_bytes + chunk_bytes > @max_stream_status_window_bytes ->
        raise GRPC.RPCError,
          status: :resource_exhausted,
          message: "payload_too_large: stream status stream exceeds byte budget"

      true ->
        current_bytes + chunk_bytes
    end
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
        status: :invalid_argument,
        message: "too many service statuses in one stream (max: #{@max_services_per_request})"
    end

    new_total
  end

  defp require_total_chunks(total_chunks) when total_chunks > @max_stream_status_chunks do
    raise GRPC.RPCError,
      status: :invalid_argument,
      message: "status stream exceeds #{@max_stream_status_chunks} chunks"
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

  @doc false
  def pin_stream_capabilities(pinned_capabilities, chunk_capabilities) do
    normalized =
      chunk_capabilities
      |> normalize_capabilities()
      |> Enum.sort()

    case pinned_capabilities do
      nil ->
        normalized

      ^normalized ->
        normalized

      _other ->
        raise GRPC.RPCError,
          status: :invalid_argument,
          message: "capabilities changed mid-stream"
    end
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

  defp ensure_stream_registration(true, _identity, _agent_id, _partition, _chunk, _stream), do: :ok

  defp chunk_metadata(
         agent_id,
         partition,
         authenticated_partition,
         peer_ip,
         chunk,
         chunk_index,
         total_chunks,
         delivery_capabilities
       ) do
    %{
      agent_id: agent_id,
      gateway_id: gateway_id(),
      partition: partition,
      authenticated_partition: authenticated_partition,
      source_ip: peer_ip,
      kv_store_id: chunk.kv_store_id,
      timestamp: System.os_time(:second),
      agent_timestamp: chunk.timestamp,
      chunk_index: chunk_index,
      total_chunks: total_chunks,
      is_final: chunk.is_final,
      delivery_capabilities: delivery_capabilities
    }
  end

  @doc false
  def process_chunk_services(services, metadata) do
    Enum.flat_map(services, fn service ->
      if strict_delivery_service?(service, metadata) do
        # Strict-delivery statuses bypass the lenient rescue for invalid payloads
        # and protocol invariants. Downstream failures are buffered before this
        # point so they do not fail the whole stream.
        {_outcome, directives} = process_service_status(service, metadata)
        directives
      else
        try do
          {_outcome, directives} = process_service_status(service, metadata)
          directives
        rescue
          e in GRPC.RPCError ->
            log_invalid_service_status(metadata, service, e)
            []

          e ->
            Logger.warning(
              "Dropping service status from agent #{metadata.agent_id} due to error: #{Exception.message(e)}"
            )

            []
        end
      end
    end)
  end

  @doc false
  def process_status_stream(status_chunks) when is_list(status_chunks) do
    case retained_stream_source(status_chunks) do
      nil ->
        directives =
          Enum.flat_map(status_chunks, fn {services, metadata} -> process_chunk_services(services, metadata) end)

        %Monitoring.GatewayStatusResponse{received: true, directives: directives}

      source ->
        process_agent_retained_stream(status_chunks, source)
    end
  end

  defp retained_stream_source(status_chunks) do
    Enum.find_value(status_chunks, fn {services, metadata} ->
      services
      |> Enum.find(&agent_retained_service?(&1, metadata))
      |> retained_service_source()
    end)
  end

  defp retained_service_source(nil), do: nil
  defp retained_service_source(service), do: normalize_service_field(service.source)

  defp process_agent_retained_stream(status_chunks, source) do
    non_empty_chunks = Enum.reject(status_chunks, fn {services, _metadata} -> services == [] end)
    validate_agent_retained_stream_isolation!(status_chunks, non_empty_chunks, source)

    prepared =
      Enum.map(non_empty_chunks, fn {[service], metadata} ->
        prepare_service_status(service, metadata)
      end)

    results = forward_agent_retained_stream(prepared, source)

    {outcome, directives} =
      Enum.reduce(results, {:agent_retained_committed, []}, fn
        {:ok, {item_outcome, item_directives}}, {outcome, directives} ->
          {combine_delivery_outcomes(outcome, item_outcome), directives ++ item_directives}

        {:exit, reason}, {_outcome, _directives} ->
          Logger.warning("Agent-retained gateway forward task exited: #{inspect(reason)}")
          {:agent_retained_uncommitted, []}
      end)

    delivery_response(outcome, directives)
  end

  defp validate_agent_retained_stream_isolation!(all_chunks, non_empty_chunks, source) do
    if non_empty_chunks == [] do
      raise GRPC.RPCError, status: :invalid_argument, message: "agent-retained stream is empty"
    end

    valid? =
      Enum.all?(non_empty_chunks, fn
        {[service], metadata} ->
          agent_retained_service?(service, metadata) and normalize_service_field(service.source) == source

        {_services, _metadata} ->
          false
      end)

    if not valid? do
      raise GRPC.RPCError,
        status: :invalid_argument,
        message: "every non-empty chunk must contain exactly one service from the same retained source"
    end

    cond do
      source == @flow_attribution_source and length(non_empty_chunks) != 1 ->
        raise GRPC.RPCError,
          status: :invalid_argument,
          message: "flow-attribution stream must contain exactly one non-empty chunk"

      source == @plugin_result_source and length(all_chunks) > @max_retained_plugin_status_chunks ->
        raise GRPC.RPCError,
          status: :invalid_argument,
          message: "retained plugin-result stream exceeds ten chunks"

      true ->
        :ok
    end
  end

  defp validate_retained_plugin_chunk_count!(services, metadata, total_chunks) do
    retained_plugin? =
      Enum.any?(services, fn service ->
        agent_retained_service?(service, metadata) and
          normalize_service_field(service.source) == @plugin_result_source
      end)

    if retained_plugin? and total_chunks > @max_retained_plugin_status_chunks do
      raise GRPC.RPCError,
        status: :invalid_argument,
        message: "retained plugin-result stream exceeds ten chunks"
    end
  end

  defp forward_agent_retained_stream(prepared, @plugin_result_source) do
    ServiceRadarAgentGateway.DeliveryTaskSupervisor
    |> Task.Supervisor.async_stream_nolink(
      prepared,
      fn {service, status} -> deliver_prepared_service_status(service, status) end,
      max_concurrency: 2,
      ordered: true,
      timeout: :infinity
    )
    |> Enum.to_list()
  end

  defp forward_agent_retained_stream(prepared, @flow_attribution_source) do
    Enum.map(prepared, fn {service, status} ->
      {:ok, deliver_prepared_service_status(service, status)}
    end)
  end

  defp next_stream_status_state(state, chunk, transition) do
    %{
      agent_id: agent_id,
      total_services: total_services,
      pinned_total_chunks: pinned_total_chunks,
      pinned_delivery_capabilities: pinned_delivery_capabilities,
      chunk_index: chunk_index,
      stream_bytes: stream_bytes,
      status_chunk: status_chunk
    } = transition

    status_chunks = [status_chunk | state.status_chunks]

    if chunk.is_final do
      validate_final_chunk!(chunk_index, pinned_total_chunks)

      {:cont,
       %{
         state
         | total_services: total_services,
           saw_final?: true,
           stream_agent_id: agent_id,
           expected_idx: chunk_index + 1,
           pinned_total_chunks: pinned_total_chunks,
           pinned_delivery_capabilities: pinned_delivery_capabilities,
           registered?: true,
           stream_bytes: stream_bytes,
           status_chunks: status_chunks
       }}
    else
      {:cont,
       %{
         state
         | total_services: total_services,
           stream_agent_id: agent_id,
           expected_idx: chunk_index + 1,
           pinned_total_chunks: pinned_total_chunks,
           pinned_delivery_capabilities: pinned_delivery_capabilities,
           registered?: true,
           stream_bytes: stream_bytes,
           status_chunks: status_chunks
       }}
    end
  end

  defp validate_final_chunk!(chunk_index, total_chunks) when chunk_index == total_chunks - 1, do: :ok

  defp validate_final_chunk!(_chunk_index, _total_chunks) do
    raise GRPC.RPCError,
      status: :invalid_argument,
      message: "final chunk_index does not match total_chunks"
  end

  defp handle_control_stream_message(message, {:awaiting_hello, nil}, identity_context, stream) do
    case message.payload do
      {:hello, %Monitoring.ControlStreamHello{} = hello} ->
        {:cont, {:ready, initialize_control_session(hello, identity_context, stream)}}

      _ ->
        raise GRPC.RPCError,
          status: :failed_precondition,
          message: "control stream requires hello as the first message"
    end
  end

  defp handle_control_stream_message(message, {:ready, session}, identity_context, _stream) do
    ControlStreamSession.handle_message(session, message, identity_context)
    {:cont, {:ready, session}}
  end

  defp initialize_control_session(hello, identity_context, stream) do
    identity = Map.fetch!(identity_context, :identity)
    agent_id = required_agent_id(hello.agent_id)
    {identity, _component_type} = resolve_component_type!(identity, agent_id)
    enforce_component_identity!(identity, agent_id, @agent_gateway_component_types)

    partition_id = resolve_partition(identity)
    capabilities = normalize_capabilities(hello.capabilities || [])
    source_ip = get_peer_ip(stream)

    ensure_agent_record(identity, agent_id, partition_id, hello, source_ip)
    ensure_device_for_agent(identity, agent_id, partition_id, hello, source_ip)
    ensure_agent_registered(identity, agent_id, partition_id, capabilities, stream)
    track_connected_agent(agent_id, partition_id, hello, source_ip)

    {:ok, session} = ControlStreamSession.start_link(stream: stream)

    register_control_session(
      session,
      agent_id,
      partition_id,
      capabilities,
      identity_context,
      hello
    )
  end

  defp register_control_session(session, agent_id, partition_id, capabilities, identity_context, hello) do
    case ControlStreamSession.register(
           session,
           agent_id,
           partition_id,
           capabilities,
           identity_context,
           hello
         ) do
      :ok ->
        Logger.info("Control stream established: agent_id=#{agent_id}, partition=#{partition_id}")
        reconcile_agent_release(agent_id)

        session

      {:error, reason} ->
        Logger.warning("Failed to register control stream for agent #{agent_id}: #{inspect(reason)}")

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
