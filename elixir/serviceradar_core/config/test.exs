import Config

alias Ecto.Adapters.SQL.Sandbox
alias ServiceRadar.DB.TestDatabaseGuard

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
        %URI{query: nil} ->
          nil

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
  Enum.find(
    [
      System.get_env("SERVICERADAR_TEST_DATABASE_URL"),
      System.get_env("SRQL_TEST_DATABASE_URL"),
      read_url_file.(System.get_env("SERVICERADAR_TEST_DATABASE_URL_FILE")),
      read_url_file.(System.get_env("SRQL_TEST_DATABASE_URL_FILE"))
    ],
    &(is_binary(&1) and String.trim(&1) != "")
  )

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

cnpg_ca =
  System.get_env("CNPG_CA_FILE") || (cnpg_cert_dir && Path.join(cnpg_cert_dir, "root.pem"))

cnpg_cert =
  System.get_env("CNPG_CERT_FILE") ||
    (cnpg_cert_dir && Path.join(cnpg_cert_dir, "workstation.pem"))

cnpg_key =
  System.get_env("CNPG_KEY_FILE") ||
    (cnpg_cert_dir && Path.join(cnpg_cert_dir, "workstation-key.pem"))

# The fixture CA, preferring the certificate ITSELF over a path to it.
#
# `*_CA_CERT` carries the PEM; `*_CA_CERT_FILE` carries a filesystem path. The content form
# is independent of the caller's path namespace, so it works inside the runner-local Bazel
# sandbox without making a rotating host path part of the action contract.
#
# The CA cannot become a declared Bazel input instead -- it is a CNPG cluster cert on a
# 90-day rotation, so a committed copy would expire on a calendar rather than on a change.
#
# The previous chain listed the CONTENT variables as fallbacks for `ssl_ca` and then passed
# the result as `:cacertfile`, i.e. handed a whole PEM where a filename was expected. That
# only ever worked because the `_FILE` variables happened to be set alongside them.
ca_pem =
  System.get_env("SERVICERADAR_TEST_DATABASE_CA_CERT") ||
    System.get_env("SRQL_TEST_DATABASE_CA_CERT")

ca_certs =
  if is_binary(ca_pem) and String.trim(ca_pem) != "" do
    ca_pem
    |> :public_key.pem_decode()
    |> Enum.filter(&match?({:Certificate, _der, _cipher}, &1))
    |> Enum.map(fn {:Certificate, der, _cipher} -> der end)
  end

ssl_ca =
  System.get_env("SERVICERADAR_TEST_DATABASE_CA_CERT_FILE") ||
    System.get_env("SRQL_TEST_DATABASE_CA_CERT_FILE") ||
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

ssl_server_name_value = ssl_server_name

ssl_server_name =
  case ssl_server_name do
    value when is_binary(value) and value != "" -> to_charlist(value)
    _ -> nil
  end

# `ca_certs` belongs here next to the path forms. Without it a CA supplied as a PATH turned
# TLS on by itself while the same CA supplied as PEM CONTENT did not -- so remotely, where no
# path variable resolves and `ssl_ca || ssl_cert || ssl_key` is always nil, TLS could only be
# switched on by `sslmode=` in the DSN. A DSN without it connected in plaintext and CNPG
# refused the connection:
#
#   FATAL 28000 (invalid_authorization_specification) pg_hba.conf rejects connection
#   for host "10.42.68.107", user "srql", database "sr_core_template", no encryption
#
# Being handed a CA means TLS was intended, whichever form it arrived in. An explicit
# sslmode=disable|allow|prefer still wins, because that clause is evaluated first.
ssl_enabled =
  cond do
    ssl_mode in ~w(disable allow prefer) -> false
    ssl_enabled -> true
    ca_certs not in [nil, []] -> true
    true -> ssl_ca || ssl_cert || ssl_key
  end

if db_url do
  Code.require_file("test_database_guard.exs", __DIR__)

  TestDatabaseGuard.validate!(db_url,
    tls_server_name: ssl_server_name_value,
    ssl_mode: ssl_mode,
    ca_configured?: ca_certs not in [nil, []] or (is_binary(ssl_ca) and ssl_ca != ""),
    template_lifecycle?: TestDatabaseGuard.template_lifecycle_authorized?()
  )
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

ownership_timeout =
  System.get_env("SERVICERADAR_TEST_DATABASE_OWNERSHIP_TIMEOUT_MS") ||
    System.get_env("SRQL_TEST_DATABASE_OWNERSHIP_TIMEOUT_MS")

pool_size = if pool_size, do: parse_int.(pool_size)
queue_target = if queue_target, do: parse_int.(queue_target)
queue_interval = if queue_interval, do: parse_int.(queue_interval)
ownership_timeout = if ownership_timeout, do: parse_int.(ownership_timeout)
search_path = System.get_env("CNPG_SEARCH_PATH", "platform, public, ag_catalog")
# The stateful alert engine fans evaluation out across N sharded GenServers
# (`StatefulAlertEngine`, default 8 shards). On a cold batch every shard
# concurrently performs its own DB reads (`load_state_snapshots` in `init`,
# `load_rules`) under the Ecto sandbox. If the pool does not exceed that
# fan-out (plus the test process and background workers), the concurrent
# shards starve waiting for a connection and the fan-out times out
# (`{:error, {:shard_exit, :timeout}}`), so alerts never fire. The previous
# `min(schedulers * 2, 8)` cap equalled the shard count exactly (zero
# headroom). Keep a floor comfortably above the shard fan-out. Explicit
# `*_DATABASE_POOL_SIZE` overrides still win for the shared fixture DB.
default_test_pool_size = max(min(System.schedulers_online() * 2, 16), 12)

# Serial integration tests share one rollback-only sandbox connection with
# their allowed child processes. DBConnection's 50 ms queue target can drop a
# legitimate child during brief contention. A finite one-second target and
# interval let the ownership proxy absorb that expected contention while still
# shedding sustained overload. Environment overrides still win, and the Repo
# pool sizes stay unchanged.
default_test_queue_target = 1_000
default_test_queue_interval = 1_000

repo_config =
  if db_url do
    base =
      [
        url: db_url,
        pool: Sandbox,
        pool_size: pool_size || default_test_pool_size,
        queue_target: queue_target || default_test_queue_target,
        queue_interval: queue_interval || default_test_queue_interval
      ]

    base =
      if ownership_timeout,
        do: Keyword.put(base, :ownership_timeout, ownership_timeout),
        else: base

    if ssl_enabled do
      put_if = fn opts, key, value ->
        if value && value != "", do: Keyword.put(opts, key, value), else: opts
      end

      ssl_opts =
        []
        # `:cacerts` (the decoded certificate) wins over `:cacertfile` (a caller-owned path)
        # so the TestRunner sandbox is path-independent. Never both: :ssl rejects the combination.
        |> then(fn opts ->
          if ca_certs in [nil, []] do
            put_if.(opts, :cacertfile, ssl_ca)
          else
            Keyword.put(opts, :cacerts, ca_certs)
          end
        end)
        |> put_if.(:certfile, ssl_cert)
        |> put_if.(:keyfile, ssl_key)
        |> put_if.(:server_name_indication, ssl_server_name)
        |> Keyword.put(:verify, if(ssl_verify, do: :verify_peer, else: :verify_none))

      Keyword.put(base, :ssl, ssl_opts)
    else
      base
    end
  else
    [
      username: "postgres",
      password: "postgres",
      hostname: "localhost",
      database: "serviceradar_test#{System.get_env("MIX_TEST_PARTITION")}",
      pool: Sandbox,
      pool_size: default_test_pool_size,
      queue_target: queue_target || default_test_queue_target,
      queue_interval: queue_interval || default_test_queue_interval
    ]
  end

# Reduce log noise in tests
config :logger, level: :warning

# Run Oban in manual testing mode so resource after_actions that enqueue
# jobs (e.g. ServiceRadar.Edge.OnboardingPackage's :create action enqueuing
# ProvisionAgentWorker) do not crash, and so worker tests can drive
# perform/1 directly or use Oban.Testing's perform_job/2 + assert_enqueued/1
# helpers. Plugins / queues / peer are disabled so AshOban schedulers and
# background workers never run during tests.
config :serviceradar_core, Oban,
  testing: :manual,
  repo: ServiceRadar.Repo,
  queues: false,
  plugins: false,
  peer: false,
  notifier: Oban.Notifiers.PG

# Use Test adapter for mailer
config :serviceradar_core, ServiceRadar.Mailer, adapter: Swoosh.Adapters.Test

config :serviceradar_core, ServiceRadar.Observability.CapacityForecasting.Worker,
  runtime_config_source: :cache

config :serviceradar_core,
       ServiceRadar.Repo,
       repo_config
       |> Keyword.put(:parameters, search_path: search_path)
       |> Keyword.put(:types, ServiceRadar.PostgresTypes)
       |> Keyword.put(:migration_default_prefix, "platform")
       # Ecto logs every query, with parameters, at :debug. Under `mix test` the :warning level
       # above hides that; under //build:elixir_tests.bzl it does NOT, because Logger boots with
       # the VM and never re-reads the level (see //build/elixir_test_config_loader.exs). The
       # serviceradar_core integration shards therefore emitted 3-13 MB of stdout each and Bazel
       # discarded the whole stream --
       #   stdout ... exceeds maximum size of --experimental_ui_max_stdouterr_bytes; skipping
       # -- taking the ExUnit failure with it, which is why four of five failing shards could not
       # be diagnosed from CI at all.
       #
       # Silencing the queries here rather than lowering the primary Logger level, which would
       # break capture_log assertions. Flip to `:debug` locally when a test needs the SQL.
       |> Keyword.put(:log, false)

# Configure Ash domains (needed for validation)
config :serviceradar_core,
  ash_domains: [
    ServiceRadar.AgentConfig,
    ServiceRadar.Camera,
    ServiceRadar.CompositeChecks,
    ServiceRadar.Credentials,
    ServiceRadar.Dashboards,
    ServiceRadar.Edge,
    ServiceRadar.Identity,
    ServiceRadar.Infrastructure,
    ServiceRadar.Integrations,
    ServiceRadar.Inventory,
    ServiceRadar.Jobs,
    ServiceRadar.Monitoring,
    ServiceRadar.Notifications,
    ServiceRadar.Observability,
    ServiceRadar.ColdTier,
    ServiceRadar.PrefixTags,
    ServiceRadar.SNMPProfiles,
    ServiceRadar.SweepJobs,
    ServiceRadar.SysmonProfiles,
    ServiceRadar.NetworkDiscovery,
    ServiceRadar.Plugins,
    ServiceRadar.Spatial,
    ServiceRadar.WifiMap,
    ServiceRadar.Automation.Northbound,
    ServiceRadar.Automation.Ansible,
    ServiceRadar.Automation.Callbacks,
    ServiceRadar.Scans,
    ServiceRadar.Security
  ]

# Disable cluster in tests by default
config :serviceradar_core,
  env: :test,
  cluster_enabled: false,
  datasvc_enabled: false,
  state_monitor_enabled: false,
  event_batcher_enabled: false,
  health_check_runner_enabled: false,
  health_check_registrar_enabled: false,
  stateful_alert_evaluation_queue:
    ServiceRadar.TestSupport.SynchronousStatefulAlertEvaluationQueue,
  service_heartbeat_enabled: false,
  spiffe_cert_monitor_enabled: false,
  status_handler_enabled: false,
  control_repo_enabled: false,
  seeders_enabled: false,
  log_promotion_consumer_enabled: false

# Prefix-tag enrichment off by default in tests; enable per-test when needed.
# Loader stays off so unit tests don't hit CNPG on application start.
config :serviceradar_core,
  prefix_tag_enrichment_enabled: false,
  # Keep provider SQL/injection path available for unit tests unless a test opts in.
  prefix_tag_provider_trie_enabled: false,
  threat_intel_engine_match_enabled: true,
  geo_tag_derivation_enabled: false,
  prefix_tags_loader_enabled: false

# Disable Swoosh API client in tests (no hackney needed)
config :swoosh, :api_client, false
