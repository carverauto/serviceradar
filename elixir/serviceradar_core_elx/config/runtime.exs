import Config

# =============================================================================
# Cluster Configuration
# =============================================================================
cluster_strategy =
  System.get_env("CLUSTER_STRATEGY", "epmd")
  |> String.downcase()

cluster_enabled = System.get_env("CLUSTER_ENABLED", "true") in ~w(true 1 yes)

topologies =
  if cluster_enabled do
    case cluster_strategy do
      "kubernetes" ->
        namespace = System.get_env("NAMESPACE", "serviceradar")
        kubernetes_selector = System.get_env("KUBERNETES_SELECTOR", "app=serviceradar")
        kubernetes_node_basename = System.get_env("KUBERNETES_NODE_BASENAME", "serviceradar")

        [
          serviceradar: [
            strategy: Cluster.Strategy.Kubernetes,
            config: [
              mode: :dns,
              kubernetes_node_basename: kubernetes_node_basename,
              kubernetes_selector: kubernetes_selector,
              kubernetes_namespace: namespace,
              polling_interval: 5_000
            ]
          ]
        ]

      "dns" ->
        dns_query = System.get_env("CLUSTER_DNS_QUERY", "serviceradar.local")
        node_basename = System.get_env("CLUSTER_NODE_BASENAME", "serviceradar")

        [
          serviceradar: [
            strategy: Cluster.Strategy.DNSPoll,
            config: [
              polling_interval: 5_000,
              query: dns_query,
              node_basename: node_basename
            ]
          ]
        ]

      "epmd" ->
        hosts_str = System.get_env("CLUSTER_HOSTS", "")

        hosts =
          hosts_str
          |> String.split(",", trim: true)
          |> Enum.map(&String.trim/1)
          |> Enum.map(&String.to_atom/1)

        if hosts != [] do
          [
            serviceradar: [
              strategy: Cluster.Strategy.Epmd,
              config: [hosts: hosts]
            ]
          ]
        else
          []
        end

      "gossip" ->
        gossip_port = String.to_integer(System.get_env("CLUSTER_GOSSIP_PORT", "45892"))
        gossip_secret = System.get_env("CLUSTER_GOSSIP_SECRET")

        if gossip_secret do
          [
            serviceradar: [
              strategy: Cluster.Strategy.Gossip,
              config: [
                port: gossip_port,
                if_addr: "0.0.0.0",
                multicast_addr: "230.1.1.1",
                multicast_ttl: 1,
                secret: gossip_secret
              ]
            ]
          ]
        else
          []
        end

      _ ->
        []
    end
  else
    []
  end

if topologies != [] do
  config :libcluster, topologies: topologies
end

# =============================================================================
# SPIFFE/mTLS Configuration
# =============================================================================
spiffe_mode =
  case System.get_env("SPIFFE_MODE", "filesystem") do
    "workload_api" -> :workload_api
    _ -> :filesystem
  end

config :serviceradar_core, :spiffe,
  mode: spiffe_mode,
  trust_domain: System.get_env("SPIFFE_TRUST_DOMAIN", "serviceradar.local"),
  cert_dir: System.get_env("SPIFFE_CERT_DIR", "/etc/serviceradar/certs"),
  workload_api_socket: System.get_env("SPIFFE_WORKLOAD_API_SOCKET", "unix:///run/spire/sockets/agent.sock")

if config_env() == :prod do
  cloak_key =
    System.get_env("CLOAK_KEY") ||
      raise """
      environment variable CLOAK_KEY is missing.
      This key is required for encrypting sensitive fields like email addresses.

      Generate a 32-byte key with:
        :crypto.strong_rand_bytes(32) |> Base.encode64()
      """

  # Core-elx is the cluster coordinator - it runs ClusterSupervisor and ClusterHealth
  cluster_coordinator =
    System.get_env("SERVICERADAR_CLUSTER_COORDINATOR", "true") in ~w(true 1 yes)

  config :serviceradar_core,
    env: :prod,
    cloak_key: cloak_key,
    repo_enabled: System.get_env("SERVICERADAR_CORE_REPO_ENABLED", "true") in ~w(true 1 yes),
    vault_enabled: System.get_env("SERVICERADAR_CORE_VAULT_ENABLED", "true") in ~w(true 1 yes),
    registries_enabled: System.get_env("SERVICERADAR_CORE_REGISTRIES_ENABLED", "true") in ~w(true 1 yes),
    cluster_enabled: cluster_enabled,
    cluster_coordinator: cluster_coordinator

  default_tenant_id =
    System.get_env("SERVICERADAR_DEFAULT_TENANT_ID") ||
      "00000000-0000-0000-0000-000000000000"

  config :serviceradar_core, :default_tenant_id, default_tenant_id

  database_url = System.get_env("DATABASE_URL")

  cnpg_host = System.get_env("CNPG_HOST")
  cnpg_port = String.to_integer(System.get_env("CNPG_PORT", "5432"))
  cnpg_database = System.get_env("CNPG_DATABASE", "serviceradar")
  cnpg_username = System.get_env("CNPG_USERNAME", "serviceradar")
  cnpg_password = System.get_env("CNPG_PASSWORD", "serviceradar")

  cnpg_ssl_mode = System.get_env("CNPG_SSL_MODE", "disable")
  cnpg_ssl_enabled = cnpg_ssl_mode != "disable"
  cnpg_tls_server_name = System.get_env("CNPG_TLS_SERVER_NAME", cnpg_host || "")

  cnpg_cert_dir = System.get_env("CNPG_CERT_DIR", "")

  cnpg_ca_file =
    System.get_env(
      "CNPG_CA_FILE",
      if(cnpg_cert_dir != "", do: Path.join(cnpg_cert_dir, "root.pem"), else: "")
    )

  cnpg_cert_file =
    System.get_env(
      "CNPG_CERT_FILE",
      if(cnpg_cert_dir != "", do: Path.join(cnpg_cert_dir, "workstation.pem"), else: "")
    )

  cnpg_key_file =
    System.get_env(
      "CNPG_KEY_FILE",
      if(cnpg_cert_dir != "", do: Path.join(cnpg_cert_dir, "workstation-key.pem"), else: "")
    )

  cnpg_verify_peer = cnpg_ssl_mode in ~w(verify-ca verify-full)

  cnpg_ssl_opts =
    [verify: if(cnpg_verify_peer, do: :verify_peer, else: :verify_none)]
    |> then(fn opts ->
      if cnpg_verify_peer and cnpg_ca_file != "" do
        Keyword.put(opts, :cacertfile, cnpg_ca_file)
      else
        opts
      end
    end)
    |> then(fn opts ->
      if cnpg_cert_file != "" and cnpg_key_file != "" do
        opts
        |> Keyword.put(:certfile, cnpg_cert_file)
        |> Keyword.put(:keyfile, cnpg_key_file)
      else
        opts
      end
    end)
    |> then(fn opts ->
      if cnpg_ssl_mode == "verify-full" and cnpg_tls_server_name != "" do
        opts
        |> Keyword.put(:server_name_indication, String.to_charlist(cnpg_tls_server_name))
        |> Keyword.put(:customize_hostname_check,
          match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
        )
      else
        opts
      end
    end)

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  repo_url =
    cond do
      database_url ->
        database_url

      cnpg_host ->
        "ecto://#{URI.encode_www_form(cnpg_username)}:#{URI.encode_www_form(cnpg_password)}@#{cnpg_host}:#{cnpg_port}/#{cnpg_database}"

      true ->
        raise """
        environment variable DATABASE_URL is missing.
        For example: ecto://USER:PASS@HOST/DATABASE
        """
    end

  config :serviceradar_core, ServiceRadar.Repo,
    url: repo_url,
    ssl: if(cnpg_ssl_enabled, do: cnpg_ssl_opts, else: false),
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    socket_options: maybe_ipv6

  oban_enabled = System.get_env("SERVICERADAR_CORE_OBAN_ENABLED", "true") in ~w(true 1 yes)
  oban_node = System.get_env("OBAN_NODE")

  oban_config = [
    engine: Oban.Engines.Basic,
    repo: ServiceRadar.Repo,
    queues: [
      default: String.to_integer(System.get_env("OBAN_QUEUE_DEFAULT") || "10"),
      alerts: String.to_integer(System.get_env("OBAN_QUEUE_ALERTS") || "5"),
      sweeps: String.to_integer(System.get_env("OBAN_QUEUE_SWEEPS") || "20"),
      edge: String.to_integer(System.get_env("OBAN_QUEUE_EDGE") || "10")
    ],
    plugins: [
      Oban.Plugins.Pruner,
      {Oban.Plugins.Cron, crontab: []}
    ]
  ]

  oban_config =
    if oban_node do
      Keyword.put(oban_config, :node, oban_node)
    else
      oban_config
    end

  config :serviceradar_core, Oban, if(oban_enabled, do: oban_config, else: false)

  # Enable AshOban scheduler - core-elx is the only service that should run schedulers
  ash_oban_scheduler_enabled =
    System.get_env("SERVICERADAR_ASH_OBAN_SCHEDULER_ENABLED", "true") in ~w(true 1 yes)

  config :serviceradar_core, :start_ash_oban_scheduler, ash_oban_scheduler_enabled

  local_mailer =
    case System.get_env("SERVICERADAR_LOCAL_MAILER") do
      "true" -> true
      "1" -> true
      "yes" -> true
      _ -> false
    end

  if local_mailer do
    config :swoosh, local: true
    config :serviceradar_core, ServiceRadar.Mailer, adapter: Swoosh.Adapters.Local
  else
    config :swoosh, :api_client, false
    config :swoosh, local: false
    config :serviceradar_core, ServiceRadar.Mailer, adapter: Swoosh.Adapters.Test
  end
end
