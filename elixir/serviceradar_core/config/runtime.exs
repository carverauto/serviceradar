import Config

# Runtime configuration for production deployments.
# This file is executed at runtime, not compile time.

if config_env() == :prod do
  # AshCloak encryption key (required for PII encryption)
  cloak_key =
    System.get_env("CLOAK_KEY") ||
      raise """
      environment variable CLOAK_KEY is missing.
      This key is required for encrypting sensitive fields like email addresses.

      Generate a 32-byte key with:
        :crypto.strong_rand_bytes(32) |> Base.encode64()
      """

  config :serviceradar_core,
    env: :prod,
    cloak_key: cloak_key

  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  ssl_mode = System.get_env("CNPG_SSL_MODE", "require")

  ssl_opts =
    case ssl_mode do
      "disable" -> false
      _ -> [verify: :verify_none]
    end

  config :serviceradar_core, ServiceRadar.Repo,
    url: database_url,
    ssl: ssl_opts,
    socket_options: maybe_ipv6,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10")

  # Cluster configuration
  config :serviceradar_core,
    cluster_enabled: System.get_env("CLUSTER_ENABLED", "true") == "true"

  # Oban configuration
  config :serviceradar_core, Oban,
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
end
