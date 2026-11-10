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

  Both carry only ephemeral status summaries, which `StatusProcessor` forwards to the core
  cluster. Durable agent data arrives as edge records (`EdgeRecordIngestServer`); a status
  from a source retired at the edge-record cutover, or an oversized summary, is refused and
  counted per agent (`RetiredStatusSources`).
  """

  use GRPC.Server, service: Monitoring.AgentGatewayService.Service

  alias ServiceRadar.Automation.Ansible.SafeFailureEvidence
  alias ServiceRadar.Edge.AgentConfigGenerator
  alias ServiceRadar.Edge.AgentGatewaySync
  alias ServiceRadarAgentGateway.AgentCertificateRevocation
  alias ServiceRadarAgentGateway.AgentRegistryProxy
  alias ServiceRadarAgentGateway.CertIssuer
  alias ServiceRadarAgentGateway.ComponentIdentityResolver
  alias ServiceRadarAgentGateway.Config
  alias ServiceRadarAgentGateway.ConfigChunks
  alias ServiceRadarAgentGateway.ConfigResponse
  alias ServiceRadarAgentGateway.ControlStreamSession
  alias ServiceRadarAgentGateway.CoreNodeForwarder
  alias ServiceRadarAgentGateway.EdgeDeliveryGrants
  alias ServiceRadarAgentGateway.MediaIdentity
  alias ServiceRadarAgentGateway.RetiredStatusSources
  alias ServiceRadarAgentGateway.StatusBuffer
  alias ServiceRadarAgentGateway.TlsDiagnosticLogger

  require Logger

  # Default heartbeat interval for agents
  @default_heartbeat_interval_sec 30

  # Maximum services per push request to prevent resource exhaustion
  @max_services_per_request 5_000
  @max_stream_status_chunks 5_000
  @max_stream_status_chunk_bytes 16 * 1024 * 1024
  @max_stream_status_window_bytes 64 * 1024 * 1024
  # A timeout here is reported to the agent as not_modified, freezing it on its
  # previous config. Must stay below the agent's 90s config deadline
  # (go/pkg/agentgateway defaultConfigTimeout) with room to stream the chunks.
  @config_core_call_timeout_ms 60_000
  @agent_gateway_component_types [:agent]
  # Status directives are asked synchronously on a push; the agent's push deadline is 30s.
  @status_directives_timeout_ms 2_000

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

    AgentCertificateRevocation.confirm_successor_hello(identity)

    # Feature support assumes the core-first rollout; each recovery RPC still
    # requires current authority and retries when core is unavailable.
    %Monitoring.AgentHelloResponse{
      accepted: true,
      agent_id: agent_id,
      message: "Agent enrolled successfully",
      gateway_id: gateway_id(),
      server_time: System.os_time(:second),
      heartbeat_interval_sec: @default_heartbeat_interval_sec,
      config_outdated: config_outdated,
      edge_recovery_protocol_version: 1
    }
  end

  @doc """
  Handle an agent mTLS certificate renewal request.

  Authenticates the caller strictly from the active gRPC stream's mTLS client
  certificate, enforces `NotBefore <= now < NotAfter` and revocation checks
  against current gateway UTC time immediately before signing, verifies the
  PKCS#10 CSR signature and identity match, issues a renewed leaf certificate
  via `CertIssuer.issue_from_csr/5`, and registers a pending predecessor
  retirement that fires only when the agent completes `Hello` presenting the
  successor certificate.
  """
  @spec renew_certificate(Monitoring.CertificateRenewalRequest.t(), GRPC.Server.Stream.t()) ::
          Monitoring.CertificateRenewalResponse.t()
  def renew_certificate(request, stream) do
    {cert_der, identity} = extract_renewal_peer_identity!(stream)
    agent_id = required_agent_id(Map.get(identity, :component_id))
    {identity, component_type} = resolve_component_type!(identity, agent_id)
    enforce_component_identity!(identity, agent_id, @agent_gateway_component_types)
    partition_id = resolve_partition(identity)
    csr_der = required_csr_der!(request)

    enforce_active_peer_certificate_for_renewal!(identity, cert_der, stream)

    opts =
      identity
      |> renewal_cert_issuer_opts()
      |> Keyword.put(:before_sign, fn ->
        enforce_active_peer_certificate_for_renewal!(identity, cert_der, stream)
      end)

    case CertIssuer.issue_from_csr(csr_der, agent_id, partition_id, component_type, opts) do
      {:ok, issued} ->
        publish_renewal_audit(issued.issuance_audit)
        :ok = AgentCertificateRevocation.register_pending_renewal(agent_id, identity, issued)

        Logger.info(
          "Agent certificate renewed: agent_id=#{agent_id}, partition=#{partition_id}, serial=#{issued.serial_number}"
        )

        %Monitoring.CertificateRenewalResponse{
          certificate_pem: issued.certificate_pem,
          ca_chain_pem: issued.ca_chain_pem,
          serial_number: issued.serial_number,
          certificate_fingerprint: issued.certificate_fingerprint,
          not_before_unix: issued.not_before_unix,
          not_after_unix: issued.not_after_unix
        }

      {:error, :csr_identity_mismatch} ->
        raise GRPC.RPCError, status: :permission_denied, message: "csr_identity_mismatch"

      {:error, reason}
      when reason in [:invalid_csr, :invalid_csr_signature, :weak_public_key, :unsupported_public_key] ->
        raise GRPC.RPCError, status: :invalid_argument, message: Atom.to_string(reason)

      {:error, :ca_not_available} ->
        raise GRPC.RPCError, status: :unavailable, message: "ca_not_available"

      {:error, reason} ->
        Logger.warning("Agent certificate renewal failed for #{agent_id}: #{inspect(reason)}")
        raise GRPC.RPCError, status: :internal, message: "certificate renewal failed"
    end
  end

  @doc "Return the core-signed certificate policy to an authenticated enrolled agent."
  def get_certificate_policy(_request, stream) do
    {cert_der, identity} = extract_renewal_peer_identity!(stream)
    agent_id = required_agent_id(Map.get(identity, :component_id))
    {identity, _type} = resolve_component_type!(identity, agent_id)
    enforce_component_identity!(identity, agent_id, @agent_gateway_component_types)
    enforce_active_peer_certificate_for_renewal!(identity, cert_der, stream)
    :ok = record_local_receiver_observations!(agent_id, stream)

    with {:ok, {:ok, envelope}} <-
           core_call(ServiceRadar.Edge.ComponentCertificateAuthority, :sign_snapshot, []),
         {:ok, payload} <- Base.decode64(envelope.payload),
         {:ok, signature} <- Base.decode64(envelope.signature) do
      %Monitoring.CertificatePolicyResponse{payload: payload, signature: signature}
    else
      _ ->
        raise GRPC.RPCError, status: :unavailable, message: "certificate policy unavailable"
    end
  end

  @doc """
  Issues delivery grants for spooled edge records whose production grant has lapsed
  (`ServiceRadarAgentGateway.EdgeDeliveryGrants`).

  The caller is the edge identity of its client certificate, resolved exactly as the edge record
  ingest stream resolves it, so a grant is bound to the principal its records must name.
  """
  @spec renew_edge_delivery_grants(Monitoring.EdgeDeliveryGrantRequest.t(), GRPC.Server.Stream.t()) ::
          Monitoring.EdgeDeliveryGrantResponse.t()
  def renew_edge_delivery_grants(request, stream) do
    identity = extract_edge_identity!(stream)

    case EdgeDeliveryGrants.renew(request, identity) do
      {:ok, response} -> response
      {:error, status, message} -> raise GRPC.RPCError, status: status, message: message
    end
  end

  def register_edge_recovery(request, stream) do
    identity = extract_edge_identity!(stream)

    case ServiceRadarAgentGateway.EdgeRecoveryControl.register(request, identity) do
      {:ok, response} -> response
      {:error, status, message} -> raise GRPC.RPCError, status: status, message: message
    end
  end

  def get_edge_recovery(request, stream) do
    identity = extract_edge_identity!(stream)

    case ServiceRadarAgentGateway.EdgeRecoveryControl.get(request, identity) do
      {:ok, response} -> response
      {:error, status, message} -> raise GRPC.RPCError, status: status, message: message
    end
  end

  def authorize_edge_recovery(request, stream) do
    identity = extract_edge_identity!(stream)

    case ServiceRadarAgentGateway.EdgeRecoveryControl.authorize(request, identity) do
      {:ok, response} -> response
      {:error, status, message} -> raise GRPC.RPCError, status: status, message: message
    end
  end

  def renew_edge_recovery_copies(request, stream) do
    identity = extract_edge_identity!(stream)

    case ServiceRadarAgentGateway.EdgeRecoveryCopyGrants.renew(request, identity) do
      {:ok, response} -> response
      {:error, status, message} -> raise GRPC.RPCError, status: status, message: message
    end
  end

  defp extract_edge_identity!(stream) do
    resolver = edge_identity_resolver()

    with {:ok, cert_der} <- MediaIdentity.peer_cert(stream),
         {:ok, %{component_type: :agent} = identity} <- resolver.resolve_edge_identity(cert_der, :agent) do
      identity
    else
      {:ok, _other_role} ->
        raise GRPC.RPCError, status: :permission_denied, message: "component type is not allowed"

      {:error, {:identity_conflict, _reason}} ->
        raise GRPC.RPCError, status: :permission_denied, message: "component identity conflict"

      {:error, reason} ->
        Logger.warning("Edge delivery grant certificate validation failed: #{inspect(reason)}")
        raise GRPC.RPCError, status: :unauthenticated, message: "invalid client certificate"
    end
  end

  defp edge_identity_resolver do
    Application.get_env(:serviceradar_agent_gateway, :edge_record_ingest_identity_resolver, ComponentIdentityResolver)
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
    |> core_call(
      :get_config_if_changed,
      [agent_id, partition_id, config_version],
      @config_core_call_timeout_ms
    )
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
      resolution_location: request.resolution_location,
      assignment_id: request.assignment_id,
      binding_id: request.binding_id
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
      |> core_call(
        :get_config_if_changed,
        [agent_id, partition_id, config_version],
        @config_core_call_timeout_ms
      )
      |> handle_config_response(agent_id, config_version)

    chunks = config_response_chunks(agent_id, response)

    Logger.info(
      "Streaming config to agent: agent_id=#{agent_id}, version=#{response.config_version}, chunks=#{length(chunks)}, bytes=#{config_response_size(response)}"
    )

    send_config_chunks(chunks, stream)
  end

  @doc """
  Handle a status push from an agent.

  Forwards the request's ephemeral status summaries to core. A status whose source carried
  durable data before the edge-record cutover, or a summary over 4096 bytes, is refused whole
  and counted for the agent (`RetiredStatusSources`); it is never published, forwarded or cut.
  A push that carried refused durable data is answered `received: false`, so the agent keeps it.
  """
  @spec push_status(Monitoring.GatewayStatusRequest.t(), GRPC.Server.Stream.t()) ::
          Monitoring.GatewayStatusResponse.t()
  def push_status(request, stream) do
    agent_id = required_agent_id(request.agent_id)
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

    Logger.debug("Received status push from agent #{agent_id}: #{service_count} services")

    # The server's gateway_id, not the request's, so an agent cannot misattribute its data.
    metadata = %{
      agent_id: agent_id,
      gateway_id: gateway_id(),
      partition: partition,
      source_ip: get_peer_ip(stream),
      kv_store_id: request.kv_store_id,
      timestamp: System.os_time(:second),
      agent_timestamp: request.timestamp
    }

    {accepted_count, response} =
      services
      |> Enum.filter(&match?(%Monitoring.GatewayServiceStatus{}, &1))
      |> Enum.map(&{&1, metadata})
      |> accept_statuses(agent_id)

    record_push_metrics(agent_id, accepted_count)
    reconcile_agent_release(agent_id)

    put_status_directives(response, agent_id, services)
  end

  @doc """
  Handle streaming status updates from an agent.

  Receives chunked status updates and handles every status of the stream as `push_status/2`
  does, once the final chunk has arrived.
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

    Logger.debug("Completed streaming status reception: #{state.total_services} total services")

    {accepted_count, response} =
      state.statuses
      |> Enum.reverse()
      |> accept_statuses(state.stream_agent_id)

    record_push_metrics(state.stream_agent_id, accepted_count)
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

  # The agent applies an endpoint inventory directive carried on any PushStatus response. Its
  # scans reach core as edge records, so the directive comes from core's record of the agent's
  # current scan, asked once per status interval: on the push carrying the agent capability
  # status. A core that does not answer in time costs the agent one interval, not the push.
  defp put_status_directives(%Monitoring.GatewayStatusResponse{received: true} = response, agent_id, services) do
    if Enum.any?(services, &capability_status?/1) do
      %{response | directives: status_directives(agent_id)}
    else
      response
    end
  end

  defp put_status_directives(response, _agent_id, _services), do: response

  defp capability_status?(%Monitoring.GatewayServiceStatus{service_name: "agent", source: "status"}), do: true
  defp capability_status?(_service), do: false

  defp status_directives(agent_id) do
    case core_call(AgentGatewaySync, :status_directives, [agent_id], @status_directives_timeout_ms) do
      {:ok, {:ok, directives}} when is_map(directives) ->
        Enum.flat_map(directives, fn {target, payload} -> gateway_status_directive(target, payload) end)

      {:ok, other} ->
        Logger.warning("Status directives for agent #{agent_id} were not available: #{inspect(other)}")
        []

      {:error, :core_unavailable} ->
        []
    end
  end

  defp gateway_status_directive(target, %{} = payload) when map_size(payload) > 0 do
    case Jason.encode(payload) do
      {:ok, payload_json} ->
        [
          %Monitoring.GatewayStatusDirective{
            service_name: to_string(target),
            service_type: to_string(target),
            directive_type: gateway_status_directive_type(target, payload),
            payload_json: payload_json
          }
        ]

      {:error, reason} ->
        Logger.warning("Dropping unencodable gateway status directive: #{inspect(reason)}")
        []
    end
  end

  defp gateway_status_directive(_target, _payload), do: []

  defp gateway_status_directive_type(target, %{"reconcile_floor" => true}), do: "#{target}.reconcile_floor"
  defp gateway_status_directive_type(target, _payload), do: "#{target}.ack"

  # Accept the statuses of one push or stream, each paired with the metadata it arrived with.
  #
  # Ephemeral summaries are handed to `StatusBuffer`, which forwards them to core after the RPC
  # has answered. Statuses from retired sources and oversized summaries are refused and counted;
  # an ephemeral status with invalid fields is dropped and logged. The response is
  # `received: false` when the agent sent statuses and none was accepted, and when any of them
  # was durable data (`RetiredStatusSources.durable?/1`): an agent built before the cutover
  # treats `received: true` as delivery of everything it sent and discards it. The summaries
  # of such a push are forwarded all the same, and the agent builds them anew every interval.
  # It never fails the RPC, because an RPC error makes the agent tear down its gateway
  # connection and its control stream with it, and that stream is how the agent receives the
  # upgrade it needs.
  defp accept_statuses(entries, agent_id) when is_list(entries) do
    {ephemeral, refused} =
      Enum.split_with(entries, fn {service, _metadata} -> RetiredStatusSources.refusal_family(service) == nil end)

    refused_statuses = Enum.map(refused, &elem(&1, 0))
    RetiredStatusSources.refuse(agent_id, refused_statuses)

    accepted_count = Enum.count(ephemeral, fn {service, metadata} -> accept_status(service, metadata) end)
    received = (entries == [] or accepted_count > 0) and not Enum.any?(refused_statuses, &RetiredStatusSources.durable?/1)

    {accepted_count, %Monitoring.GatewayStatusResponse{received: received}}
  end

  defp accept_status(service, metadata) do
    {service_name, service_type, source} = normalized_service_fields(service)
    validate_service_fields!(service_name, service_type, source)

    service
    |> build_service_status(metadata, service_name, service_type, source)
    |> buffer_status()

    true
  rescue
    e in GRPC.RPCError ->
      log_invalid_service_status(metadata, service, e)
      false
  end

  # The agent does not keep a summary it has sent. Reply now and let the bounded buffer forward
  # it; a full or missing buffer drops it and counts the drop.
  defp buffer_status(status) do
    case StatusBuffer.enqueue(status) do
      :ok ->
        StatusBuffer.request_flush()

      {:error, :unavailable} ->
        Logger.warning("Status buffer did not accept #{status.source} status from agent #{status.agent_id}")
        StatusBuffer.record_drop(status, :unavailable)
    end
  end

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
      message: service_message(service.message),
      service_type: service_type,
      response_time: normalize_response_time(service.response_time),
      agent_id: metadata.agent_id,
      gateway_id: metadata.gateway_id,
      partition: normalize_partition(service.partition || metadata.partition),
      source: source,
      source_ip: metadata.source_ip,
      kv_store_id: service.kv_store_id || metadata.kv_store_id,
      timestamp: metadata.timestamp,
      agent_timestamp: metadata.agent_timestamp,
      request_id: Logger.metadata()[:request_id]
    }
  end

  defp service_message(message) when is_binary(message), do: message
  defp service_message(_message), do: ""

  defp normalize_response_time(rt) when is_integer(rt) and rt >= 0 and rt <= 86_400_000, do: rt
  defp normalize_response_time(rt) when is_integer(rt) and rt > 86_400_000, do: 86_400_000
  defp normalize_response_time(_), do: 0

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
    # Status is not part of a push. The registry proxy marks `:connected`
    # only after the control session is monitored.
    metadata = %{
      partition_id: partition_id,
      domain: Config.domain(),
      capabilities: capabilities,
      gateway_id: Config.gateway_id(),
      source_ip: get_peer_ip(stream)
    }

    metadata = compact_metadata(metadata)

    # nil means a heartbeat that cannot renegotiate capabilities. An explicit
    # list comes from authenticated hello and must also be able to clear a
    # previously negotiated capability set.
    if is_list(capabilities), do: Map.put(metadata, :capabilities, capabilities), else: metadata
  end

  defp ensure_agent_record(identity, agent_id, partition_id, request, source_ip) do
    attrs = agent_record_attrs(identity, agent_id, partition_id, request, source_ip)

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
        deployment_type: label_value(labels, [:deployment_type, "deployment_type"]),
        edge_record_spool: edge_record_spool(request)
      })

    ServiceRadar.AgentTracker.track_agent(agent_id, metadata)
  rescue
    _ -> :ok
  end

  @doc false
  def device_attrs_from_request(partition_id, request, source_ip) do
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
      host_macs: request_value(request, :host_macs) || [],
      host_interfaces: host_interfaces_from_request(request),
      host_tls_fingerprints: host_tls_fingerprints_from_request(request),
      capabilities: capabilities
    }
  end

  # Certificates the agent's own host services present (today: a Proxmox VE node's
  # pve-ssl.pem), as plain maps. Core decides whether they identify the host.
  defp host_tls_fingerprints_from_request(request) do
    request
    |> request_value(:host_tls_fingerprints)
    |> List.wrap()
    |> Enum.map(fn fingerprint ->
      %{port: Map.get(fingerprint, :port), sha256: Map.get(fingerprint, :sha256)}
    end)
  end

  # The agent's classified interface inventory, as plain maps: core decides which of these
  # MACs identify the host (AgentGatewaySync). Agents that predate it send none.
  defp host_interfaces_from_request(request) do
    request
    |> request_value(:host_interfaces)
    |> List.wrap()
    |> Enum.map(fn iface ->
      %{
        name: Map.get(iface, :name),
        mac: Map.get(iface, :mac),
        permanent_mac: Map.get(iface, :permanent_mac),
        ips: Map.get(iface, :ips) || [],
        oper_state: Map.get(iface, :oper_state),
        kind: Map.get(iface, :kind),
        mac_provenance: Map.get(iface, :mac_provenance),
        master: Map.get(iface, :master)
      }
    end)
  end

  defp touch_agent_record(identity, agent_id, partition_id, source_ip, config_source) do
    attrs =
      identity
      |> agent_record_attrs(agent_id, partition_id, nil, source_ip)
      |> maybe_add_config_source(config_source)

    # Fire-and-forget: heartbeat updates are non-critical and must not block the
    # PushStatus response. A slow or unavailable core causes DEADLINE_EXCEEDED on
    # the agent side if this runs synchronously. Task.start (not start_link) so
    # a crash in the background task does not propagate to the handler process.
    Task.start(fn ->
      case core_call(AgentGatewaySync, :heartbeat_agent, [agent_id, attrs]) do
        {:ok, :ok} ->
          :ok

        {:ok, {:error, reason}} ->
          Logger.warning("Failed to heartbeat agent record #{agent_id}: #{inspect(reason)}")

        {:error, :core_unavailable} ->
          Logger.warning("Core unavailable while updating agent #{agent_id}")
      end
    end)

    :ok
  end

  defp maybe_add_config_source(attrs, nil), do: attrs

  defp maybe_add_config_source(attrs, config_source), do: Map.put(attrs, :config_source, config_source)

  defp agent_record_attrs(identity, agent_id, partition_id, request, source_ip) do
    metadata =
      %{
        gateway_id: Config.gateway_id(),
        partition_id: partition_id,
        domain: Config.domain(),
        source_ip: source_ip
      }
      |> Map.merge(request_metadata(request))
      |> compact_metadata()

    cert_attrs = extract_identity_cert_attrs(identity)

    %{
      uid: agent_id,
      name: request_value(request, :hostname),
      version: request_value(request, :version),
      type_id: 4,
      gateway_id: Config.gateway_id(),
      capabilities: request_capabilities(request),
      host: request_value(request, :hostname),
      ip: source_ip,
      metadata: metadata
    }
    |> Map.merge(cert_attrs)
    |> compact_metadata()
  end

  defp extract_identity_cert_attrs(identity) when is_map(identity) do
    cert_expires_at = Map.get(identity, :cert_expires_at) || Map.get(identity, :cert_not_after)

    cert_fingerprint =
      Map.get(identity, :cert_fingerprint_sha256) || Map.get(identity, :certificate_fingerprint)

    compact_metadata(%{
      cert_not_before: Map.get(identity, :cert_not_before),
      cert_expires_at: cert_expires_at,
      cert_serial: Map.get(identity, :cert_serial),
      cert_fingerprint_sha256: cert_fingerprint,
      cert_renewed_at: Map.get(identity, :cert_renewed_at)
    })
  end

  defp extract_identity_cert_attrs(_identity), do: %{}

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
      deployment_type: label_value(labels, [:deployment_type, "deployment_type"]),
      edge_record_spool: edge_record_spool(request)
    }

    compact_metadata(base)
  end

  # Startup availability and live health of the edge-record spool. An agent that predates the default-on
  # sender reports nothing, which core shows as agent_upgrade_pending; a spool that did not
  # open is spool_unavailable (ServiceRadar.Edge.PipelineReadiness).
  defp edge_record_spool(%{edge_record_spool: %Monitoring.EdgeRecordSpoolStatus{} = spool}) do
    spool
    |> Map.take([
      :available,
      :error,
      :health_available,
      :health_error,
      :wedged,
      :gap_sequences,
      :gap_count,
      :unresolved_count,
      :oldest_unresolved_age_seconds,
      :oldest_unresolved_age_known,
      :unresolved_bytes,
      :bytes_used,
      :budget_bytes,
      :admission_paused,
      :retained_legacy_bytes
    ])
    |> Map.put(
      :generation_gaps,
      Enum.map(spool.generation_gaps, fn gap ->
        %{
          spool_generation_id: Base.encode16(gap.spool_generation_id, case: :lower),
          route_profile: gap.route_profile,
          traffic_class: gap.traffic_class,
          sequence: gap.sequence
        }
      end)
    )
  end

  defp edge_record_spool(_request), do: nil

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

  # Renewal has no requesting core/web node. Forward only metadata, off the
  # response path, through the same core discovery/RPC used by AgentGatewaySync.
  defp publish_renewal_audit(audit) do
    case Task.Supervisor.start_child(ServiceRadarAgentGateway.DeliveryTaskSupervisor, fn ->
           forward_renewal_audit(audit)
         end) do
      {:ok, _pid} -> :ok
      {:error, reason} -> renewal_audit_failed(audit, reason)
    end
  catch
    :exit, reason -> renewal_audit_failed(audit, reason)
  end

  defp forward_renewal_audit(audit) do
    case core_call(ServiceRadar.Edge.CertificateIssuanceAudit, :publish, [%{issuance_audit: audit}]) do
      {:ok, _bundle} -> :ok
      {:error, reason} -> renewal_audit_failed(audit, reason)
    end
  rescue
    error -> renewal_audit_failed(audit, error)
  catch
    :exit, reason -> renewal_audit_failed(audit, reason)
  end

  defp renewal_audit_failed(audit, reason) do
    :telemetry.execute(
      [:serviceradar, :audit, :publish_failed],
      %{count: 1},
      %{resource_type: audit[:resource_type], action: audit[:action]}
    )

    Logger.warning("Certificate renewal audit forwarding failed: #{inspect(reason)}")
  end

  defp record_local_receiver_observations!(agent_id, stream) do
    case local_receiver_fingerprints(stream) do
      [] ->
        :ok

      fingerprints ->
        case core_call(ServiceRadar.Edge.ManagedCertificateLifecycle, :accept_local_receiver, [
               agent_id,
               fingerprints
             ]) do
          {:ok, {:ok, recorded}} when is_list(recorded) ->
            GRPC.Server.set_trailers(stream, %{"x-serviceradar-recorded-certs" => Enum.join(recorded, ",")})
            :ok

          other ->
            Logger.warning("Local certificate receiver observation failed for #{agent_id}: #{inspect(other)}")

            raise GRPC.RPCError, status: :unavailable, message: "certificate observation unavailable"
        end
    end
  end

  defp local_receiver_fingerprints(stream) do
    stream
    |> request_headers()
    |> header_value("x-serviceradar-observed-certs")
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&Regex.match?(~r/\A[0-9a-f]{64}\z/, &1))
    |> Enum.uniq()
    |> Enum.take(32)
  end

  defp header_value(headers, name) when is_map(headers) do
    headers |> Map.get(name) |> header_text()
  end

  defp header_value(_, _), do: ""

  defp header_text(nil), do: ""
  defp header_text(value) when is_binary(value), do: value

  defp header_text(value) when is_list(value) do
    cond do
      Enum.all?(value, &is_binary/1) -> Enum.join(value, ",")
      Enum.all?(value, &is_integer/1) -> to_string(value)
      true -> ""
    end
  end

  defp header_text(value), do: to_string(value)

  defp request_headers(%{http_request_headers: headers}) when is_map(headers) and map_size(headers) > 0,
    do: normalize_headers(headers)

  defp request_headers(%{adapter: adapter, payload: payload}) when is_atom(adapter) do
    cond do
      function_exported?(adapter, :get_headers, 1) ->
        normalize_headers(adapter.get_headers(payload))

      function_exported?(:cowboy_req, :headers, 1) ->
        try do
          normalize_headers(:cowboy_req.headers(payload))
        rescue
          _ -> %{}
        end

      true ->
        %{}
    end
  end

  defp request_headers(_), do: %{}

  defp normalize_headers(headers) when is_map(headers) do
    Map.new(headers, fn {key, value} -> {header_name(key), value} end)
  end

  defp normalize_headers(headers) when is_list(headers) do
    Map.new(headers, fn {key, value} -> {header_name(key), value} end)
  end

  defp normalize_headers(_), do: %{}

  defp header_name(key) when is_atom(key), do: key |> Atom.to_string() |> String.downcase()
  defp header_name(key) when is_binary(key), do: String.downcase(key)
  defp header_name(key), do: key |> to_string() |> String.downcase()

  defp core_call(module, function, args, timeout \\ 5_000) do
    case CoreNodeForwarder.call(module, function, args, timeout: timeout) do
      {:ok, result} ->
        {:ok, result}

      {:error, :peer_too_old} ->
        {:error, :core_unavailable}

      {:error, {:badrpc, reason}} ->
        Logger.warning(
          "Core RPC call failed: #{inspect(reason)}. " <>
            "Calling #{inspect(module)}.#{function}"
        )

        {:error, :core_unavailable}

      {:error, :core_unavailable} ->
        Logger.warning(
          "Core call failed: no core nodes available. Connected nodes: #{inspect(Node.list())}. " <>
            "Calling #{inspect(module)}.#{function}"
        )

        {:error, :core_unavailable}
    end
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
    case get_peer_cert(stream) do
      {:ok, cert_der} ->
        case ComponentIdentityResolver.resolve_from_cert(cert_der) do
          {:ok, identity} ->
            %{
              identity: identity,
              component_id: Map.get(identity, :component_id),
              partition_id: Map.get(identity, :partition_id),
              component_type: Map.get(identity, :component_type),
              cert_fingerprint_sha256: cert_fingerprint_sha256(cert_der),
              cert_serial: Map.get(identity, :cert_serial),
              cert_not_before: Map.get(identity, :cert_not_before),
              cert_not_after: Map.get(identity, :cert_not_after),
              cert_expires_at: Map.get(identity, :cert_expires_at)
            }

          {:error, reason} ->
            _ =
              TlsDiagnosticLogger.log_handshake_failure(
                reason,
                cert_der,
                peer_ip: get_peer_ip(stream)
              )

            raise GRPC.RPCError, status: :unauthenticated, message: "invalid client certificate"
        end

      {:error, reason} ->
        _ =
          TlsDiagnosticLogger.log_handshake_failure(
            reason,
            nil,
            peer_ip: get_peer_ip(stream)
          )

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

  @doc false
  def config_payload_summary(config) when is_map(config) do
    config_json = Map.get(config, :config_json) || ""

    %{
      config_json_bytes: byte_size(config_json),
      mapper_jobs: config_mapper_job_count(config),
      plugins: config_plugin_assignment_count(config)
    }
  end

  defp config_mapper_job_count(%{mapper_jobs_count: count}) when is_integer(count) and count >= 0, do: count

  defp config_mapper_job_count(_config), do: 0

  defp config_plugin_assignment_count(%{plugins: plugins}) when is_list(plugins), do: length(plugins)

  defp config_plugin_assignment_count(_config), do: 0

  defp initial_stream_status_state do
    %{
      total_services: 0,
      saw_final?: false,
      stream_agent_id: nil,
      expected_idx: 0,
      pinned_total_chunks: nil,
      registered?: false,
      stream_bytes: 0,
      statuses: []
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
    chunk_index = validate_chunk_index!(chunk.chunk_index || 0, total_chunks, state.expected_idx)
    partition = resolve_partition(identity)
    metadata = chunk_metadata(agent_id, partition, peer_ip, chunk)

    Logger.debug("Received chunk #{chunk_index + 1}/#{total_chunks} from agent #{agent_id}")

    ensure_stream_registration(state.registered?, identity, agent_id, partition, chunk, stream)

    if chunk.is_final, do: validate_final_chunk!(chunk_index, pinned_total_chunks)

    {:cont,
     %{
       state
       | total_services: total_services,
         saw_final?: chunk.is_final == true,
         stream_agent_id: agent_id,
         expected_idx: chunk_index + 1,
         pinned_total_chunks: pinned_total_chunks,
         registered?: true,
         stream_bytes: stream_bytes,
         statuses: Enum.reduce(services, state.statuses, &[{&1, metadata} | &2])
     }}
  end

  @doc false
  def stream_status_chunk_size(%Monitoring.GatewayStatusChunk{} = chunk) do
    chunk
    |> Protobuf.Encoder.encode_to_iodata()
    |> IO.iodata_length()
  end

  @doc false
  defdelegate config_response_chunks(agent_id, response), to: ConfigChunks, as: :chunks

  @doc false
  def send_config_chunks(chunks, stream) when is_list(chunks) do
    _stream =
      Enum.reduce(chunks, stream, fn %Monitoring.AgentConfigChunk{} = chunk, stream ->
        GRPC.Server.send_reply(stream, chunk)
      end)

    :ok
  end

  @doc false
  defdelegate config_response_size(response), to: ConfigChunks, as: :size

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
    |> Enum.filter(&match?(%Monitoring.GatewayServiceStatus{}, &1))
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

  defp chunk_metadata(agent_id, partition, peer_ip, chunk) do
    %{
      agent_id: agent_id,
      gateway_id: gateway_id(),
      partition: partition,
      source_ip: peer_ip,
      kv_store_id: chunk.kv_store_id,
      timestamp: System.os_time(:second),
      agent_timestamp: chunk.timestamp
    }
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
    identity_context = Map.put(identity_context, :identity, identity)

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

    AgentCertificateRevocation.confirm_successor_hello(identity)
    session
  end

  defp extract_renewal_peer_identity!(stream) do
    now = renewal_now()

    case get_peer_cert(stream) do
      {:ok, cert_der} ->
        case ComponentIdentityResolver.resolve_from_cert(cert_der, now: now) do
          {:ok, identity} ->
            {cert_der, identity}

          {:error, :certificate_expired} ->
            _ =
              TlsDiagnosticLogger.log_handshake_failure(
                :certificate_expired,
                cert_der,
                peer_ip: get_peer_ip(stream)
              )

            raise GRPC.RPCError, status: :permission_denied, message: "certificate_expired"

          {:error, :certificate_not_yet_valid} ->
            _ =
              TlsDiagnosticLogger.log_handshake_failure(
                :certificate_not_yet_valid,
                cert_der,
                peer_ip: get_peer_ip(stream)
              )

            raise GRPC.RPCError, status: :permission_denied, message: "certificate_not_yet_valid"

          {:error, :revoked_certificate} ->
            _ =
              TlsDiagnosticLogger.log_handshake_failure(
                :revoked_certificate,
                cert_der,
                peer_ip: get_peer_ip(stream)
              )

            raise GRPC.RPCError, status: :permission_denied, message: "certificate_revoked"

          {:error, reason} ->
            _ =
              TlsDiagnosticLogger.log_handshake_failure(
                reason,
                cert_der,
                peer_ip: get_peer_ip(stream)
              )

            raise GRPC.RPCError, status: :unauthenticated, message: "invalid client certificate"
        end

      {:error, reason} ->
        _ =
          TlsDiagnosticLogger.log_handshake_failure(
            reason,
            nil,
            peer_ip: get_peer_ip(stream)
          )

        raise GRPC.RPCError, status: :unauthenticated, message: "invalid client certificate"
    end
  end

  defp required_csr_der!(%Monitoring.CertificateRenewalRequest{csr_der: csr_der})
       when is_binary(csr_der) and byte_size(csr_der) > 0 do
    csr_der
  end

  defp required_csr_der!(_request) do
    raise GRPC.RPCError, status: :invalid_argument, message: "csr_der is required"
  end

  defp enforce_active_peer_certificate_for_renewal!(identity, cert_der, stream) do
    now = renewal_now()
    not_before = Map.get(identity, :cert_not_before)
    not_after = Map.get(identity, :cert_not_after) || Map.get(identity, :cert_expires_at)

    cond do
      match?(%DateTime{}, not_before) and DateTime.before?(now, not_before) ->
        _ =
          TlsDiagnosticLogger.log_handshake_failure(
            :certificate_not_yet_valid,
            cert_der,
            peer_ip: get_peer_ip(stream)
          )

        raise GRPC.RPCError, status: :permission_denied, message: "certificate_not_yet_valid"

      match?(%DateTime{}, not_after) and DateTime.compare(now, not_after) in [:eq, :gt] ->
        _ =
          TlsDiagnosticLogger.log_handshake_failure(
            :certificate_expired,
            cert_der,
            peer_ip: get_peer_ip(stream)
          )

        raise GRPC.RPCError, status: :permission_denied, message: "certificate_expired"

      AgentCertificateRevocation.revoked?(identity) ->
        _ =
          TlsDiagnosticLogger.log_handshake_failure(
            :revoked_certificate,
            cert_der,
            peer_ip: get_peer_ip(stream)
          )

        raise GRPC.RPCError, status: :permission_denied, message: "certificate_revoked"

      true ->
        :ok
    end
  end

  defp renewal_now do
    case Application.get_env(:serviceradar_agent_gateway, :cert_issuer_opts, [])[:now] do
      %DateTime{} = now -> now
      now_fn when is_function(now_fn, 0) -> now_fn.()
      _ -> DateTime.utc_now()
    end
  end

  defp renewal_cert_issuer_opts(identity) do
    configured_opts = Application.get_env(:serviceradar_agent_gateway, :cert_issuer_opts, [])

    Keyword.merge(configured_opts,
      audit_action: :agent_certificate_renew,
      authorized_component_id: Map.get(identity, :component_id),
      authorized_partition_id: Map.get(identity, :partition_id),
      predecessor_certificate_fingerprint: Map.get(identity, :certificate_fingerprint),
      predecessor_certificate_serial_number: Map.get(identity, :serial_number),
      audit_actor: %{
        id: Map.get(identity, :component_id),
        spiffe_id: Map.get(identity, :spiffe_id),
        certificate_fingerprint: Map.get(identity, :certificate_fingerprint)
      }
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
    # Fire-and-forget: reconcile is non-critical and must not block the handler
    # response. A 15-second synchronous call here causes DEADLINE_EXCEEDED when
    # core is slow. Task.start (not start_link) so a crash does not propagate.
    Task.start(fn ->
      core_call(AgentGatewaySync, :reconcile_agent_release, [agent_id], 15_000)
    end)

    :ok
  end
end
