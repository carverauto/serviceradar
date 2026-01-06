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
  - `GATEWAY_TENANT_ID` - Tenant UUID for multi-tenant deployments
  - `GATEWAY_TENANT_SLUG` - Tenant slug for multi-tenant deployments
  - `CLUSTER_HOSTS` - Comma-separated list of cluster nodes to join

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

  require Logger

  @impl true
  def start(_type, _args) do
    partition_id = System.get_env("GATEWAY_PARTITION_ID", "default")

    gateway_id = System.get_env("GATEWAY_ID", generate_gateway_id())
    domain = System.get_env("GATEWAY_DOMAIN", "default")
    tenant_id = System.get_env("GATEWAY_TENANT_ID")
    tenant_slug = System.get_env("GATEWAY_TENANT_SLUG")

    # Gateway gRPC server configuration
    grpc_port = get_grpc_port()
    grpc_ssl_opts = get_grpc_ssl_opts()

    capabilities = parse_capabilities(System.get_env("GATEWAY_CAPABILITIES", ""))

    if tenant_slug do
      Logger.info(
        "Starting ServiceRadar Agent Gateway: #{gateway_id} in partition: #{partition_id} for tenant: #{tenant_slug}"
      )
    else
      Logger.info(
        "Starting ServiceRadar Agent Gateway: #{gateway_id} in partition: #{partition_id}"
      )
    end

    Logger.info("Agent Gateway gRPC server listening on port #{grpc_port}")

    core_children =
      [
        pubsub_child(),
        repo_child(),
        tenant_registry_child(),
        gateway_tracker_child(),
        agent_tracker_child(),
        cluster_supervisor_child()
      ]
      |> List.flatten()
      |> Enum.reject(&is_nil/1)

    gateway_children = [
      ServiceRadarAgentGateway.AgentRegistryProxy,
      # Gateway-specific configuration store
      {ServiceRadarAgentGateway.Config,
       partition_id: partition_id,
       gateway_id: gateway_id,
       domain: domain,
       capabilities: capabilities,
       tenant_id: tenant_id,
       tenant_slug: tenant_slug},

      # Registration worker - registers this gateway in the distributed registry.
      # Gateways are platform-level; tenant context is derived per-request via mTLS.
      {ServiceRadar.Gateway.RegistrationWorker,
       partition_id: partition_id,
       gateway_id: gateway_id,
       domain: domain,
       entity_type: :gateway,
       tenant_id: tenant_id},
      # Register gateway for platform-wide visibility (Infrastructure UI).
      {ServiceRadar.GatewayRegistrationWorker,
       gateway_id: gateway_id,
       partition: partition_id,
       domain: domain},

      # gRPC server that receives status pushes from Go agents
      {GRPC.Server.Supervisor,
       endpoint: ServiceRadarAgentGateway.Endpoint,
       port: grpc_port,
       start_server: true,
       adapter_opts: build_adapter_opts(grpc_ssl_opts)},

      # gRPC client for communicating with Go agents (legacy support)
      ServiceRadarAgentGateway.AgentClient,

      # Task executor - executes polling tasks from the core
      ServiceRadarAgentGateway.TaskExecutor
    ]

    children = core_children ++ gateway_children

    opts = [strategy: :one_for_one, name: ServiceRadarAgentGateway.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp get_grpc_port do
    port_str = System.get_env("GATEWAY_GRPC_PORT", "50052")

    case Integer.parse(port_str) do
      {port, ""} when port > 0 and port < 65_536 ->
        port

      _ ->
        Logger.warning("Invalid GATEWAY_GRPC_PORT=#{inspect(port_str)}; defaulting to 50052")
        50_052
    end
  end

  defp get_grpc_ssl_opts do
    # Try SPIFFE certs first, then fall back to mounted certs
    case ServiceRadar.SPIFFE.server_ssl_opts() do
      {:ok, ssl_opts} ->
        Logger.info("Using SPIFFE mTLS for agent gateway gRPC server")
        GRPC.Credential.new(ssl: ssl_opts)

      {:error, _reason} ->
        # Fall back to mounted certificates
        get_mounted_ssl_opts()
    end
  end

  defp get_mounted_ssl_opts do
    cert_dir = System.get_env("GATEWAY_CERT_DIR", "/etc/serviceradar/certs")
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

      Logger.info("Using mounted mTLS certs for agent gateway gRPC server: #{cert_file}")
      GRPC.Credential.new(ssl: ssl_opts)
    else
      # Fail closed by default - require explicit opt-in for insecure connections
      allow_insecure? = System.get_env("GATEWAY_ALLOW_INSECURE_GRPC", "false") == "true"

      if allow_insecure? do
        Logger.warning(
          "No mTLS certs available; GATEWAY_ALLOW_INSECURE_GRPC=true so starting insecure gRPC (DEV ONLY)"
        )

        nil
      else
        raise "No mTLS certs available for agent gateway gRPC server (set GATEWAY_ALLOW_INSECURE_GRPC=true to override for local dev)"
      end
    end
  end

  defp generate_gateway_id do
    hostname =
      case :inet.gethostname() do
        {:ok, name} -> List.to_string(name)
        _ -> "unknown"
      end

    suffix =
      8
      |> :crypto.strong_rand_bytes()
      |> Base.encode16(case: :lower)

    "gateway-#{hostname}-#{suffix}"
  end

  defp repo_child do
    if Application.get_env(:serviceradar_core, :repo_enabled, true) do
      if Process.whereis(ServiceRadar.Repo) do
        nil
      else
        ServiceRadar.Repo
      end
    else
      nil
    end
  end

  defp pubsub_child do
    if Process.whereis(ServiceRadar.PubSub) do
      nil
    else
      {Phoenix.PubSub, name: ServiceRadar.PubSub}
    end
  end

  defp tenant_registry_child do
    if Process.whereis(ServiceRadar.Cluster.TenantRegistry) do
      nil
    else
      ServiceRadar.Cluster.TenantRegistry
    end
  end

  defp gateway_tracker_child do
    if Process.whereis(ServiceRadar.GatewayTracker) do
      nil
    else
      ServiceRadar.GatewayTracker
    end
  end

  defp agent_tracker_child do
    if Process.whereis(ServiceRadar.AgentTracker) do
      nil
    else
      ServiceRadar.AgentTracker
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

  defp build_adapter_opts(nil), do: []
  defp build_adapter_opts(cred), do: [cred: cred]
end
