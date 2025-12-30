defmodule ServiceRadarWebNG.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    # Auto-start distributed Erlang if not already running and cluster is enabled
    maybe_start_distribution()

    # Force load ServiceRadarWebNGWeb early to ensure atoms like :current_user exist
    # in the atom table before AshAuthentication.Phoenix.LiveSession uses them.
    # See: AshAuthentication.Phoenix.LiveSession.generate_session/3 line 236
    _ = ServiceRadarWebNGWeb.__ash_auth_atoms__()

    children = [
      # Web telemetry
      ServiceRadarWebNGWeb.Telemetry,
      # GRPC client supervisor for datasvc connections
      {GRPC.Client.Supervisor, []},
      # DNS cluster for Kubernetes deployments
      {DNSCluster,
       query: Application.get_env(:serviceradar_web_ng, :dns_cluster_query) || :ignore},
      # Phoenix PubSub for web-specific real-time features
      {Phoenix.PubSub, name: ServiceRadarWebNG.PubSub},
      # Start to serve requests, typically the last entry
      ServiceRadarWebNGWeb.Endpoint
    ]

    # Ensure ServiceRadar.Repo is started (may already be started by serviceradar_core)
    ensure_repo_started()

    # Check core-elx availability for cluster coordination
    check_core_elx_health()

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: ServiceRadarWebNG.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    ServiceRadarWebNGWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  # Auto-start distributed Erlang for cluster connectivity
  defp maybe_start_distribution do
    cluster_enabled? = System.get_env("CLUSTER_ENABLED", "false") == "true"
    tls_dist? = System.get_env("ENABLE_TLS_DIST", "false") == "true"

    case {Node.alive?(), cluster_enabled?, tls_dist?} do
      {true, _, _} ->
        Logger.info("Node already distributed: #{Node.self()}")
        maybe_connect_to_cluster()
        :ok

      {false, false, _} ->
        Logger.debug("Cluster not enabled, running as standalone node")
        :ok

      {false, true, true} ->
        # TLS distribution must be configured at VM startup via:
        # elixir --erl "-proto_dist inet_tls -ssl_dist_optfile /path/to/ssl_dist.conf"
        Logger.warning(
          "CLUSTER_ENABLED=true but ENABLE_TLS_DIST=true and node not distributed. " <>
            "Use ./dev-cluster.sh to start with TLS distribution."
        )

        :ok

      {false, true, false} ->
        start_distribution()
    end
  end

  defp start_distribution do
    ip = detect_ip_address()
    node_name = :"serviceradar_web_ng@#{ip}"
    cookie = String.to_atom(System.get_env("RELEASE_COOKIE", "serviceradar_dev_cookie"))

    Logger.info("Starting distributed Erlang as #{node_name}")

    # Start EPMD if not running
    case System.cmd("epmd", ["-daemon"], stderr_to_stdout: true) do
      {_, 0} -> :ok
      # Already running
      {_, 1} -> :ok
      {output, code} -> Logger.warning("EPMD start returned #{code}: #{output}")
    end

    # Small delay for EPMD to be ready
    Process.sleep(100)

    case Node.start(node_name, :longnames) do
      {:ok, _pid} ->
        Node.set_cookie(cookie)
        Logger.info("Node started successfully as #{Node.self()} with cookie")
        maybe_connect_to_cluster()
        :ok

      {:error, reason} ->
        Logger.error("Failed to start distributed node: #{inspect(reason)}")
        :error
    end
  end

  defp detect_ip_address do
    # Try multiple methods to detect the appropriate IP
    with :error <- get_env_ip(),
         :error <- get_docker_gateway_ip(),
         :error <- get_default_interface_ip() do
      Logger.warning("Could not detect IP, falling back to 127.0.0.1")
      "127.0.0.1"
    end
  end

  defp get_env_ip do
    case System.get_env("NODE_IP") do
      nil -> :error
      ip -> ip
    end
  end

  defp get_docker_gateway_ip do
    # Try to get the docker network gateway IP
    network = System.get_env("DOCKER_NETWORK", "serviceradar_serviceradar-net")

    case System.cmd(
           "docker",
           [
             "network",
             "inspect",
             network,
             "--format",
             "{{range .IPAM.Config}}{{.Gateway}}{{end}}"
           ],
           stderr_to_stdout: true
         ) do
      {ip, 0} when ip != "" ->
        String.trim(ip)

      _ ->
        :error
    end
  end

  defp get_default_interface_ip do
    # Get IP from hostname or default interface
    case :inet.getif() do
      {:ok, interfaces} ->
        # Find first non-loopback interface
        interfaces
        |> Enum.find(fn {{a, _, _, _}, _, _} -> a != 127 end)
        |> case do
          {{a, b, c, d}, _, _} -> "#{a}.#{b}.#{c}.#{d}"
          nil -> :error
        end

      _ ->
        :error
    end
  end

  defp maybe_connect_to_cluster do
    # Try to connect to known cluster hosts
    hosts = System.get_env("CLUSTER_HOSTS", "")

    if hosts != "" do
      hosts
      |> String.split(",")
      |> Enum.each(&try_connect_to_node/1)
    end
  end

  defp try_connect_to_node(host) do
    node = String.to_atom(String.trim(host))
    Logger.debug("Attempting to connect to #{node}")

    case Node.connect(node) do
      true -> Logger.info("Connected to #{node}")
      false -> Logger.debug("Could not connect to #{node} (may not be up yet)")
      :ignored -> Logger.debug("Connection to #{node} ignored")
    end
  end

  # Ensure the database Repo is started
  # This is a safety net in case serviceradar_core didn't start it
  defp ensure_repo_started do
    case GenServer.whereis(ServiceRadar.Repo) do
      pid when is_pid(pid) ->
        Logger.debug("ServiceRadar.Repo already started (pid: #{inspect(pid)})")
        :ok

      nil ->
        Logger.info("Starting ServiceRadar.Repo from web-ng application")

        case ServiceRadar.Repo.start_link([]) do
          {:ok, pid} ->
            Logger.info("ServiceRadar.Repo started successfully (pid: #{inspect(pid)})")
            :ok

          {:error, {:already_started, pid}} ->
            Logger.debug("ServiceRadar.Repo already started (pid: #{inspect(pid)})")
            :ok

          {:error, reason} ->
            Logger.error("Failed to start ServiceRadar.Repo: #{inspect(reason)}")
            :error
        end
    end
  end

  # Check if core-elx (cluster coordinator) is available
  # web-ng depends on core-elx for cluster coordination (ClusterSupervisor/ClusterHealth)
  # This is a non-blocking check - web-ng can still function without core-elx
  defp check_core_elx_health do
    cluster_enabled? = System.get_env("CLUSTER_ENABLED", "false") == "true"

    if cluster_enabled? do
      # Give the cluster a moment to form
      Task.start(fn ->
        # Wait a bit for cluster connections to establish
        Process.sleep(2000)
        do_core_elx_health_check()
      end)

      :ok
    else
      Logger.debug("Cluster not enabled, skipping core-elx health check")
      :ok
    end
  end

  defp do_core_elx_health_check do
    case ServiceRadar.Cluster.ClusterStatus.find_coordinator() do
      nil ->
        Logger.warning("""
        [web-ng] No core-elx coordinator found in cluster.

        web-ng can still function but cluster status will show limited information.
        Ensure core-elx is running with cluster_coordinator: true.

        Connected nodes: #{inspect(Node.list())}
        """)

        :no_coordinator

      coordinator_node ->
        Logger.info("[web-ng] Found core-elx coordinator: #{coordinator_node}")
        :ok
    end
  rescue
    e ->
      Logger.warning("[web-ng] Error checking core-elx health: #{inspect(e)}")
      :error
  end
end
