defmodule ServiceRadarAgentGateway.Application do
  @moduledoc """
  ServiceRadar Agent Gateway Application.

  This is a standalone Elixir release that runs in our infrastructure
  (Kubernetes) and joins the ServiceRadar ERTS cluster. It receives
  status pushes from Go agents deployed in customer networks.

  The agent gateway is responsible for:
  - Joining the distributed ERTS cluster via mTLS
  - Registering itself in the Horde distributed registry
  - Receiving gRPC status pushes from Go agents
  - Forwarding monitoring data to the core cluster

  ## Agent Communication

  Go agents initiate all connections to the gateway via gRPC:
  - Agents push status updates to the gateway (default port 50052)
  - Communication flows UP only (agent → gateway)
  - Gateway never connects back to agents

  This architecture ensures:
  - Agents can connect outbound through firewalls
  - No inbound firewall rules needed in customer networks
  - Secure communication via mTLS

  ## Environment Variables

  - `GATEWAY_PARTITION_ID` - The partition this gateway belongs to
  - `GATEWAY_ID` - Unique identifier for this gateway
  - `GATEWAY_DOMAIN` - The domain this gateway handles
  - `GATEWAY_GRPC_PORT` - gRPC port for receiving agent pushes (default: 50052)
  - `GATEWAY_METRICS_PORT` - HTTP port for Prometheus metrics (default: 9090)
  - `GATEWAY_CAPABILITIES` - Comma-separated list of capabilities (icmp, tcp, http, etc.)
  - `CLUSTER_HOSTS` - Comma-separated list of cluster nodes to join

  Note: Request context is derived from mTLS certificates.

  ## Architecture

  ```
  ┌────────────────────────────────────────────────────────────┐
  │                    Customer Network (Edge)                  │
  │  ┌───────────────┐                                         │
  │  │  Go Agent     │                                         │
  │  │  (gRPC Client)│──┐                                      │
  │  └───────────────┘  │                                      │
  └─────────────────────┼──────────────────────────────────────┘
                        │ gRPC/mTLS (outbound)
                        │
  ┌─────────────────────┼──────────────────────────────────────┐
  │                     ▼                                      │
  │  ┌───────────────────────┐                                 │
  │  │  Agent Gateway        │                                 │
  │  │  (gRPC Server)        │                                 │
  │  └───────────┬───────────┘                                 │
  │              │ ERTS/mTLS                                   │
  │              ▼                                             │
  │  ┌─────────────┐  ┌──────────────┐  ┌───────────────┐      │
  │  │ Horde       │  │ libcluster   │  │ Status        │      │
  │  │ Registry    │  │              │  │ Processor     │      │
  │  └─────────────┘  └──────────────┘  └───────────────┘      │
  │                    ServiceRadar Infrastructure (K8s)       │
  └────────────────────────────────────────────────────────────┘
  ```

  ERTS cluster stays within our infrastructure (K8s).
  Customer network only needs outbound gRPC connectivity to the gateway.
  """

  use Application

  alias ServiceRadar.Edge.PublisherSupervisor
  alias ServiceRadar.NATS.Connection
  alias ServiceRadar.Telemetry.OtelSetup

  require Logger

  @impl true
  def start(_type, _args) do
    partition_id = System.get_env("GATEWAY_PARTITION_ID", "default")

    gateway_id = System.get_env("GATEWAY_ID", generate_gateway_id())
    domain = System.get_env("GATEWAY_DOMAIN", "default")

    # Gateway gRPC server configuration
    grpc_port = get_grpc_port()

    capabilities = parse_capabilities(System.get_env("GATEWAY_CAPABILITIES", ""))

    # Initialize gateway identity config (persistent_term, not a process)
    ServiceRadarAgentGateway.Config.setup(
      gateway_id: gateway_id,
      domain: domain,
      capabilities: capabilities
    )

    # Attach OTEL auto-instrumentation handlers (SDK configured in runtime.exs)
    OtelSetup.attach_instrumentations(instrumentations: [])

    Logger.info("Starting ServiceRadar Agent Gateway: #{gateway_id}, domain: #{domain}")

    # NOTE: Gateway does NOT start Repo - it has no database access.
    # All database-dependent operations are forwarded to core-elx via RPC.
    core_children = core_children()

    registries_enabled = Application.get_env(:serviceradar_core, :registries_enabled, true)

    # Registration workers require ProcessRegistry (Horde)
    registration_children =
      if registries_enabled do
        [
          # Registration worker - registers this gateway in the distributed registry.
          # Gateways are platform-level; request context is derived per-request via mTLS.
          {ServiceRadar.Gateway.RegistrationWorker,
           partition_id: partition_id, gateway_id: gateway_id, domain: domain, entity_type: :gateway},
          # Register gateway for platform-wide visibility (Infrastructure UI).
          {ServiceRadar.GatewayRegistrationWorker, gateway_id: gateway_id, partition: partition_id, domain: domain}
        ]
      else
        []
      end

    gateway_children =
      [
        ServiceRadarAgentGateway.Telemetry
      ] ++
        metrics_children() ++
        [
          {Task.Supervisor, name: ServiceRadarAgentGateway.DeliveryTaskSupervisor},
          ServiceRadarAgentGateway.AgentRegistryProxy,
          ServiceRadarAgentGateway.AgentCertificateRevocation,
          ServiceRadarAgentGateway.ControlStreamTelemetry,
          ServiceRadarAgentGateway.StatusBuffer,
          ServiceRadarAgentGateway.CameraMediaSessionTracker,
          ServiceRadarAgentGateway.DesktopMediaSessionTracker,
          ServiceRadarAgentGateway.DesktopMediaCloseReconciler

          # NOTE: Legacy polling modules (AgentClient, TaskExecutor) have been deleted.
          # In the new push-only architecture, agents push status to the gateway.
          # The gateway never initiates connections to agents.
        ] ++ edge_listener_children(grpc_port) ++ registration_children

    children = core_children ++ gateway_children

    opts = [strategy: :one_for_one, name: ServiceRadarAgentGateway.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @doc """
  The core children this application composes, as a list.

  Public so ROOT COMPOSITION can be asserted. That is not testable from the running tree in every
  environment: under Bazel the gateway application is not started, so a test that inspected
  `Supervisor.which_children/1` passed locally and failed there -- for the right reason, but only
  by accident of where it ran. Deleting an entry from this list is invisible to every behavioural
  test, so the list itself is what a test has to bind.
  """
  def core_children do
    [
      pubsub_child(),
      nats_connection_child(),
      edge_publisher_pools_child(),
      process_registry_child(),
      gateway_tracker_child(),
      agent_tracker_child(),
      cluster_supervisor_child()
    ]
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
  end

  defp get_grpc_port do
    port_value =
      Application.get_env(:serviceradar_agent_gateway, :gateway_grpc_port) ||
        System.get_env("GATEWAY_GRPC_PORT", "50052")

    case parse_port(port_value) do
      {port, ""} when port > 0 and port < 65_536 ->
        port

      _ ->
        Logger.warning("Invalid GATEWAY_GRPC_PORT=#{inspect(port_value)}; defaulting to 50052")
        50_052
    end
  end

  defp get_artifact_server_opts(ssl_opts) do
    [
      port: get_artifact_port(),
      scheme: :https,
      certfile: Keyword.fetch!(ssl_opts, :certfile),
      keyfile: Keyword.fetch!(ssl_opts, :keyfile),
      cacertfile: Keyword.fetch!(ssl_opts, :cacertfile)
    ]
  end

  defp edge_listener_children(grpc_port) do
    if Application.get_env(:serviceradar_agent_gateway, :edge_listeners_enabled, true) do
      ssl_server_opts = edge_server_ssl_opts!()
      grpc_ssl_opts = GRPC.Credential.new(ssl: ssl_server_opts)
      artifact_server_opts = get_artifact_server_opts(ssl_server_opts)

      Logger.info("Agent Gateway gRPC server listening on port #{grpc_port}")

      Logger.info("Agent Gateway artifact server listening on port #{artifact_server_opts[:port]}")

      [
        # gRPC server that receives status pushes from Go agents
        {GRPC.Server.Supervisor,
         endpoint: ServiceRadarAgentGateway.Endpoint,
         port: grpc_port,
         start_server: true,
         adapter_opts: edge_grpc_adapter_opts(grpc_ssl_opts)},
        ServiceRadarAgentGateway.ReleaseArtifactServer.child_spec(artifact_server_opts)
      ]
    else
      Logger.warning("Agent Gateway edge listeners disabled by configuration")
      []
    end
  end

  defp get_artifact_port do
    port_value =
      Application.get_env(:serviceradar_agent_gateway, :gateway_artifact_port) ||
        System.get_env("GATEWAY_ARTIFACT_PORT", "50053")

    case parse_port(port_value) do
      {port, ""} when port > 0 and port < 65_536 ->
        port

      _ ->
        Logger.warning("Invalid GATEWAY_ARTIFACT_PORT=#{inspect(port_value)}; defaulting to 50053")

        50_053
    end
  end

  defp parse_port(value) when is_integer(value), do: {value, ""}
  defp parse_port(value) when is_binary(value), do: Integer.parse(value)
  defp parse_port(_value), do: :error

  defp metrics_children do
    opts = Application.get_env(:serviceradar_agent_gateway, :metrics, [])

    if Keyword.get(opts, :enabled, true) do
      [{ServiceRadarAgentGateway.MetricsRouter, opts}]
    else
      []
    end
  end

  @doc false
  def edge_server_ssl_opts! do
    cert_dir =
      Application.get_env(:serviceradar_agent_gateway, :gateway_cert_dir) ||
        System.get_env("GATEWAY_CERT_DIR", "/etc/serviceradar/certs")

    cert_file = Path.join(cert_dir, "gateway.pem")
    key_file = Path.join(cert_dir, "gateway-key.pem")
    ca_file = Path.join(cert_dir, "root.pem")

    if File.exists?(cert_file) and File.exists?(key_file) and File.exists?(ca_file) do
      ssl_opts = [
        certfile: cert_file,
        keyfile: key_file,
        cacertfile: ca_file,
        verify: :verify_peer,
        fail_if_no_peer_cert: true
      ]

      Logger.info("Using mounted mTLS certs for agent gateway servers: #{cert_file}")
      ssl_opts
    else
      raise "No mTLS certs available for agent gateway edge listeners"
    end
  end

  defp generate_gateway_id do
    {:ok, hostname} = :inet.gethostname()
    hostname = List.to_string(hostname)

    suffix =
      8
      |> :crypto.strong_rand_bytes()
      |> Base.encode16(case: :lower)

    "gateway-#{hostname}-#{suffix}"
  end

  defp pubsub_child do
    if Process.whereis(ServiceRadar.PubSub) do
      nil
    else
      {Phoenix.PubSub, name: ServiceRadar.PubSub}
    end
  end

  defp nats_connection_child do
    if gateway_publisher_enabled?() do
      if Process.whereis(Connection.connection_name()) do
        nil
      else
        ServiceRadar.NATS.Supervisor
      end
    end
  end

  # Use the same enablement gate as the shared NATS connection. PublisherSupervisor owns
  # lane connections and pools; LaneSupervisor owns their startup and readiness ordering.
  defp edge_publisher_pools_child do
    if gateway_publisher_enabled?() do
      if Process.whereis(PublisherSupervisor) do
        nil
      else
        PublisherSupervisor
      end
    end
  end

  defp gateway_publisher_enabled? do
    Enum.any?(
      [
        :sysmon_metrics_publisher,
        :snmp_metrics_publisher,
        :icmp_metrics_publisher,
        :plugin_metrics_publisher,
        :rperf_metrics_publisher,
        :mtr_metrics_publisher,
        :sweep_metrics_publisher,
        :otlp_relay_publisher,
        :edge_records_publisher
      ],
      fn key ->
        :serviceradar_agent_gateway
        |> Application.get_env(key, [])
        |> Keyword.get(:enabled, false)
      end
    )
  end

  defp process_registry_child do
    # ProcessRegistry provides singleton Horde registry + DynamicSupervisor
    # Disabled in tests via config to avoid Horde clustering issues
    if Application.get_env(:serviceradar_core, :registries_enabled, true) do
      # Check if it's already started (by serviceradar_core)
      registry_name = ServiceRadar.ProcessRegistry.registry_name()

      if Process.whereis(registry_name) do
        nil
      else
        ServiceRadar.ProcessRegistry.child_specs()
      end
    end
  end

  defp gateway_tracker_child do
    if Application.get_env(:serviceradar_core, :registries_enabled, true) do
      if Process.whereis(ServiceRadar.GatewayTracker) do
        nil
      else
        ServiceRadar.GatewayTracker
      end
    end
  end

  defp agent_tracker_child do
    if Application.get_env(:serviceradar_core, :registries_enabled, true) do
      if Process.whereis(ServiceRadar.AgentTracker) do
        nil
      else
        ServiceRadar.AgentTracker
      end
    end
  end

  defp cluster_supervisor_child do
    if Process.whereis(ServiceRadar.ClusterSupervisor) do
      nil
    else
      ServiceRadar.ClusterSupervisor
    end
  end

  @allowed_capabilities %{
    "icmp" => :icmp,
    "tcp" => :tcp,
    "http" => :http,
    "grpc" => :grpc,
    "snmp" => :snmp,
    "dns" => :dns,
    "custom" => :custom
  }

  defp parse_capabilities(capabilities_str) do
    capabilities_str
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.flat_map(fn cap ->
      key = String.downcase(cap)

      case Map.fetch(@allowed_capabilities, key) do
        {:ok, atom} ->
          [atom]

        :error ->
          Logger.warning("Ignoring unknown capability: #{inspect(cap)}")
          []
      end
    end)
  end

  @doc false
  def edge_grpc_adapter_opts(cred) do
    [
      cred: cred,
      idle_timeout: positive_integer_env("GATEWAY_GRPC_IDLE_TIMEOUT_MS", 30_000),
      inactivity_timeout: positive_integer_env("GATEWAY_GRPC_INACTIVITY_TIMEOUT_MS", 10_000),
      max_concurrent_streams: positive_integer_env("GATEWAY_GRPC_MAX_CONCURRENT_STREAMS", 100),
      max_connections: positive_integer_env("GATEWAY_GRPC_MAX_CONNECTIONS", 1_000),
      max_frame_size_received: positive_integer_env("GATEWAY_GRPC_MAX_FRAME_SIZE_BYTES", 16_777_215),
      reset_idle_timeout_on_send: true
    ]
  end

  defp positive_integer_env(name, default) do
    name
    |> System.get_env()
    |> parse_positive_integer(default, name)
  end

  defp parse_positive_integer(nil, default, _name), do: default

  defp parse_positive_integer(value, default, name) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 ->
        parsed

      _ ->
        Logger.warning("Invalid #{name}=#{inspect(value)}; defaulting to #{default}")
        default
    end
  end
end
