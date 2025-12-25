import Config

# Disable Swoosh API client in tests (no hackney needed)
config :swoosh, :api_client, false

# Use Test adapter for mailer
config :serviceradar_core, ServiceRadar.Mailer,
  adapter: Swoosh.Adapters.Test

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

db_url =
  System.get_env("SRQL_TEST_DATABASE_URL") ||
    System.get_env("SERVICERADAR_TEST_DATABASE_URL") ||
    read_url_file.(System.get_env("SRQL_TEST_DATABASE_URL_FILE")) ||
    read_url_file.(System.get_env("SERVICERADAR_TEST_DATABASE_URL_FILE"))

ssl_enabled = System.get_env("SRQL_TEST_DATABASE_SSL", "false") in ~w(true 1 yes)
ssl_ca = System.get_env("SRQL_TEST_DATABASE_CA_CERT")

repo_config =
  if db_url do
    base = [
      url: db_url,
      pool: Ecto.Adapters.SQL.Sandbox,
      pool_size: System.schedulers_online() * 2
    ]

    if ssl_enabled do
      ssl_opts =
        if ssl_ca do
          [cacertfile: ssl_ca]
        else
          []
        end

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
  cluster_enabled: false

# Oban in test mode (real DB, real queues)
config :serviceradar_core, Oban,
  repo: ServiceRadar.Repo

# Reduce log noise in tests
config :logger, level: :warning
