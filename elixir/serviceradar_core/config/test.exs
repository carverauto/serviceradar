import Config

# Disable Swoosh API client in tests (no hackney needed)
config :swoosh, :api_client, false

# Use Test adapter for mailer
config :serviceradar_core, ServiceRadar.Mailer, adapter: Swoosh.Adapters.Test

# Test database configuration
read_url_file = fn
  nil ->
    nil

  path ->
    case File.read(path) do
      {:ok, contents} ->
        case String.trim(contents) do
          "" -> nil
          value -> value
        end

      _ ->
        nil
    end
end

env_true? = fn
  value when value in ["true", "1", "yes"] -> true
  _ -> false
end

parse_int = fn value ->
  case Integer.parse(to_string(value)) do
    {int, _} -> int
    _ -> nil
  end
end

parse_sslmode = fn
  nil ->
    nil

  url ->
    try do
      case URI.parse(url) do
        %URI{query: nil} -> nil
        %URI{query: query} ->
          case URI.decode_query(query) do
            %{"sslmode" => mode} -> String.downcase(mode)
            _ -> nil
          end
      end
    rescue
      _ -> nil
    end
end

db_url =
  System.get_env("SERVICERADAR_TEST_DATABASE_URL") ||
    System.get_env("SRQL_TEST_DATABASE_URL") ||
    read_url_file.(System.get_env("SERVICERADAR_TEST_DATABASE_URL_FILE")) ||
    read_url_file.(System.get_env("SRQL_TEST_DATABASE_URL_FILE"))

ssl_mode =
  parse_sslmode.(db_url) ||
    System.get_env("SERVICERADAR_TEST_DATABASE_SSLMODE") ||
    System.get_env("SRQL_TEST_DATABASE_SSLMODE") ||
    System.get_env("CNPG_SSL_MODE")

ssl_mode =
  case ssl_mode do
    nil -> nil
    mode -> String.downcase(mode)
  end

ssl_enabled =
  env_true?.(System.get_env("SERVICERADAR_TEST_DATABASE_SSL")) ||
    env_true?.(System.get_env("SRQL_TEST_DATABASE_SSL")) ||
    ssl_mode in ~w(require verify-ca verify-full)

ssl_verify =
  env_true?.(System.get_env("SERVICERADAR_TEST_DATABASE_SSL_VERIFY")) ||
    env_true?.(System.get_env("SRQL_TEST_DATABASE_SSL_VERIFY")) ||
    ssl_mode in ~w(verify-ca verify-full)

cnpg_cert_dir = System.get_env("CNPG_CERT_DIR")
cnpg_ca = System.get_env("CNPG_CA_FILE") || (cnpg_cert_dir && Path.join(cnpg_cert_dir, "root.pem"))
cnpg_cert = System.get_env("CNPG_CERT_FILE") || (cnpg_cert_dir && Path.join(cnpg_cert_dir, "workstation.pem"))
cnpg_key = System.get_env("CNPG_KEY_FILE") || (cnpg_cert_dir && Path.join(cnpg_cert_dir, "workstation-key.pem"))

ssl_ca =
  System.get_env("SERVICERADAR_TEST_DATABASE_CA_CERT") ||
    System.get_env("SRQL_TEST_DATABASE_CA_CERT") ||
    cnpg_ca

ssl_cert =
  System.get_env("SERVICERADAR_TEST_DATABASE_CERT") ||
    System.get_env("SRQL_TEST_DATABASE_CERT") ||
    cnpg_cert

ssl_key =
  System.get_env("SERVICERADAR_TEST_DATABASE_KEY") ||
    System.get_env("SRQL_TEST_DATABASE_KEY") ||
    cnpg_key

ssl_server_name =
  System.get_env("SERVICERADAR_TEST_DATABASE_SERVER_NAME") ||
    System.get_env("SRQL_TEST_DATABASE_SERVER_NAME") ||
    System.get_env("CNPG_TLS_SERVER_NAME")

ssl_enabled =
  cond do
    ssl_mode in ~w(disable allow prefer) -> false
    ssl_enabled -> true
    true -> ssl_ca || ssl_cert || ssl_key
  end

pool_size =
  System.get_env("SERVICERADAR_TEST_DATABASE_POOL_SIZE") ||
    System.get_env("SRQL_TEST_DATABASE_POOL_SIZE")

queue_target =
  System.get_env("SERVICERADAR_TEST_DATABASE_QUEUE_TARGET_MS") ||
    System.get_env("SRQL_TEST_DATABASE_QUEUE_TARGET_MS")

queue_interval =
  System.get_env("SERVICERADAR_TEST_DATABASE_QUEUE_INTERVAL_MS") ||
    System.get_env("SRQL_TEST_DATABASE_QUEUE_INTERVAL_MS")

pool_size = if pool_size, do: parse_int.(pool_size), else: nil
queue_target = if queue_target, do: parse_int.(queue_target), else: nil
queue_interval = if queue_interval, do: parse_int.(queue_interval), else: nil

repo_config =
  if db_url do
    base =
      [
        url: db_url,
        pool: Ecto.Adapters.SQL.Sandbox,
        pool_size: pool_size || System.schedulers_online() * 2
      ]
      |> then(fn opts ->
        if queue_target, do: Keyword.put(opts, :queue_target, queue_target), else: opts
      end)
      |> then(fn opts ->
        if queue_interval, do: Keyword.put(opts, :queue_interval, queue_interval), else: opts
      end)

    if ssl_enabled do
      put_if = fn opts, key, value ->
        if value && value != "", do: Keyword.put(opts, key, value), else: opts
      end

      ssl_opts =
        []
        |> put_if.(:cacertfile, ssl_ca)
        |> put_if.(:certfile, ssl_cert)
        |> put_if.(:keyfile, ssl_key)
        |> put_if.(:server_name_indication, ssl_server_name)
        |> Keyword.put(:verify, if(ssl_verify, do: :verify_peer, else: :verify_none))

      Keyword.merge(base, ssl: true, ssl_opts: ssl_opts)
    else
      base
    end
  else
    [
      username: "postgres",
      password: "postgres",
      hostname: "localhost",
      database: "serviceradar_test#{System.get_env("MIX_TEST_PARTITION")}",
      pool: Ecto.Adapters.SQL.Sandbox,
      pool_size: System.schedulers_online() * 2
    ]
  end

config :serviceradar_core, ServiceRadar.Repo, repo_config

# Disable cluster in tests by default
config :serviceradar_core,
  env: :test,
  cluster_enabled: false,
  datasvc_enabled: false,
  state_monitor_enabled: false,
  event_batcher_enabled: false,
  health_check_runner_enabled: false,
  health_check_registrar_enabled: false,
  service_heartbeat_enabled: false,
  spiffe_cert_monitor_enabled: false

# Disable Oban in tests to avoid AshOban.Scheduler issues
config :serviceradar_core, Oban, false

# Configure Ash domains (needed for validation)
config :serviceradar_core,
  ash_domains: [
    ServiceRadar.Edge,
    ServiceRadar.Identity,
    ServiceRadar.Infrastructure,
    ServiceRadar.Integrations,
    ServiceRadar.Inventory,
    ServiceRadar.Jobs,
    ServiceRadar.Monitoring,
    ServiceRadar.Observability
  ]

# Reduce log noise in tests
config :logger, level: :warning
