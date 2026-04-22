import Config

alias Geolix.Adapter.MMDB2
alias Swoosh.Adapters.Local

require Logger

parse_int_env = fn env_name, default ->
  case System.get_env(env_name) do
    nil ->
      default

    "" ->
      default

    value ->
      case Integer.parse(value) do
        {int, ""} when int > 0 -> int
        _ -> default
      end
  end
end

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/serviceradar_web_ng start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :serviceradar_web_ng, ServiceRadarWebNGWeb.Endpoint, server: true
end

# =============================================================================
# OpenTelemetry Configuration
# =============================================================================
# All OTEL exporter config MUST live here — runtime.exs runs before OTP apps
# start, so the opentelemetry SDK picks up these values at boot.
otel_endpoint = System.get_env("OTEL_EXPORTER_OTLP_ENDPOINT")

if otel_endpoint do
  ssl_opts = ServiceRadar.Telemetry.OtelSetup.ssl_options()
  otel_rpc_timeout_ms = parse_int_env.("OTEL_EXPORTER_OTLP_TIMEOUT_MS", 30_000)
  otel_retry_max_attempts = parse_int_env.("OTEL_EXPORTER_OTLP_RETRY_MAX_ATTEMPTS", 3)
  otel_retry_base_delay_ms = parse_int_env.("OTEL_EXPORTER_OTLP_RETRY_BASE_DELAY_MS", 500)
  otel_retry_max_delay_ms = parse_int_env.("OTEL_EXPORTER_OTLP_RETRY_MAX_DELAY_MS", 10_000)

  config :opentelemetry,
    span_processor: :batch,
    traces_exporter:
      {:serviceradar_otel_exporter_traces_otlp,
       %{
         rpc_timeout_ms: otel_rpc_timeout_ms,
         retry_max_attempts: otel_retry_max_attempts,
         retry_base_delay_ms: otel_retry_base_delay_ms,
         retry_max_delay_ms: otel_retry_max_delay_ms
       }}

  # Log exporter uses the same endpoint/protocol/TLS as traces
  config :opentelemetry_experimental,
    otlp_protocol: :grpc,
    otlp_endpoint: otel_endpoint,
    ssl_options: ssl_opts

  config :opentelemetry_exporter,
    otlp_protocol: :grpc,
    otlp_endpoint: otel_endpoint,
    ssl_options: ssl_opts
else
  config :opentelemetry,
    traces_exporter: :none
end

# GeoLite2 MMDB configuration (for GeoIP/ASN enrichment via Geolix).
# Note: when `serviceradar_core` is used as a dependency in the web-ng release, its
# `config/runtime.exs` is not executed; we must configure Geolix here too.
geolite_dir = System.get_env("GEOLITE_MMDB_DIR", "/var/lib/serviceradar/geoip")

geolite_city_enabled =
  "GEOLITE_CITY_ENABLED"
  |> System.get_env("false")
  |> String.downcase()
  |> Kernel.in(["1", "true", "yes", "on"])

base_geolite_dbs = [
  %{
    id: :geolite2_asn,
    adapter: MMDB2,
    source: Path.join(geolite_dir, "GeoLite2-ASN.mmdb")
  },
  %{
    id: :geolite2_country,
    adapter: MMDB2,
    source: Path.join(geolite_dir, "GeoLite2-Country.mmdb")
  }
]

city_geolite_dbs =
  (geolite_city_enabled &&
     [
       %{
         id: :geolite2_city,
         adapter: MMDB2,
         source: Path.join(geolite_dir, "GeoLite2-City.mmdb")
       }
     ]) || []

ipinfo_dbs = [
  %{
    id: :ipinfo_lite,
    adapter: MMDB2,
    source: Path.join(geolite_dir, "ipinfo_lite.mmdb")
  }
]

api_keys =
  System.get_env("SERVICERADAR_API_KEYS") ||
    System.get_env("SERVICERADAR_API_KEY")

config :geolix, databases: base_geolite_dbs ++ city_geolite_dbs ++ ipinfo_dbs

config :serviceradar_core,
  geolite_mmdb_dir: geolite_dir

if api_keys do
  keys =
    api_keys
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))

  if keys != [] do
    config :serviceradar_web_ng, :api_auth, api_keys: keys
  end
end

god_view_enabled =
  "SERVICERADAR_GOD_VIEW_ENABLED"
  |> System.get_env("false")
  |> String.downcase()
  |> Kernel.in(["1", "true", "yes", "on"])

runtime_capabilities_env = System.get_env("SERVICERADAR_RUNTIME_CAPABILITIES")

normalize_runtime_capability = fn
  capability when is_binary(capability) ->
    case String.downcase(String.trim(capability)) do
      "collectors_enabled" -> :collectors_enabled
      "leaf_nodes_enabled" -> :leaf_nodes_enabled
      "device_limit_enforcement_enabled" -> :device_limit_enforcement_enabled
      _ -> nil
    end

  _ ->
    nil
end

runtime_capabilities =
  case runtime_capabilities_env do
    nil ->
      [configured?: false, enabled: []]

    raw ->
      enabled =
        raw
        |> String.split(",", trim: true)
        |> Enum.map(normalize_runtime_capability)
        |> Enum.reject(&is_nil/1)

      [configured?: true, enabled: enabled]
  end

plugin_storage_defaults = Application.get_env(:serviceradar_web_ng, :plugin_storage, [])
plugin_storage_backend = System.get_env("PLUGIN_STORAGE_BACKEND")
plugin_storage_path = System.get_env("PLUGIN_STORAGE_PATH")
plugin_storage_bucket = System.get_env("PLUGIN_STORAGE_BUCKET")
plugin_verification_defaults = Application.get_env(:serviceradar_web_ng, :plugin_verification, [])
client_ip_defaults = Application.get_env(:serviceradar_web_ng, :client_ip, [])

read_secret_env = fn env_name, file_env_name ->
  case System.get_env(env_name) do
    nil ->
      case System.get_env(file_env_name) do
        nil -> nil
        "" -> nil
        path -> path |> File.read!() |> String.trim()
      end

    "" ->
      nil

    value ->
      value
  end
end

plugin_storage_signing_secret =
  read_secret_env.("PLUGIN_STORAGE_SIGNING_SECRET", "PLUGIN_STORAGE_SIGNING_SECRET_FILE")

to_int = fn value ->
  cond do
    is_integer(value) ->
      value

    is_binary(value) ->
      case Integer.parse(String.trim(value)) do
        {parsed, ""} -> parsed
        _ -> nil
      end

    true ->
      nil
  end
end

to_bool = fn value ->
  cond do
    is_boolean(value) ->
      value

    is_binary(value) ->
      case String.downcase(String.trim(value)) do
        "true" -> true
        "1" -> true
        "yes" -> true
        "false" -> false
        "0" -> false
        "no" -> false
        _ -> nil
      end

    true ->
      nil
  end
end

to_csv_list = fn value ->
  cond do
    is_list(value) ->
      value

    is_binary(value) ->
      value
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    true ->
      nil
  end
end

to_csv_map = fn value ->
  cond do
    is_map(value) ->
      value

    is_binary(value) ->
      value
      |> String.split(",", trim: true)
      |> Enum.reduce(%{}, fn entry, acc ->
        case String.split(entry, "=", parts: 2) do
          [key, val] ->
            key = String.trim(key)
            val = String.trim(val)

            if key == "" or val == "" do
              acc
            else
              Map.put(acc, key, val)
            end

          _ ->
            acc
        end
      end)

    true ->
      nil
  end
end

maybe_put_mailer_credential = fn config, key, value ->
  case value do
    nil -> config
    "" -> config
    _ -> Keyword.put(config, key, value)
  end
end

normalize_plugin_backend = fn value ->
  cond do
    is_atom(value) ->
      value

    is_binary(value) ->
      case String.downcase(String.trim(value)) do
        "jetstream" -> :jetstream
        "filesystem" -> :filesystem
        _ -> :filesystem
      end

    true ->
      :filesystem
  end
end

normalize_js_storage = fn value ->
  cond do
    is_atom(value) ->
      value

    is_binary(value) ->
      case String.downcase(String.trim(value)) do
        "memory" -> :memory
        "file" -> :file
        _ -> :file
      end

    true ->
      :file
  end
end

maybe_put_env = fn acc, key, value, transform ->
  cond do
    is_nil(value) ->
      acc

    value == "" ->
      acc

    true ->
      case transform.(value) do
        nil -> acc
        result -> Keyword.put(acc, key, result)
      end
  end
end

maybe_put_env_simple = fn acc, key, value ->
  cond do
    is_nil(value) -> acc
    value == "" -> acc
    true -> Keyword.put(acc, key, value)
  end
end

plugin_storage_overrides =
  []
  |> maybe_put_env.(:backend, plugin_storage_backend, normalize_plugin_backend)
  |> maybe_put_env_simple.(:base_path, plugin_storage_path)
  |> maybe_put_env.(
    :upload_ttl_seconds,
    System.get_env("PLUGIN_STORAGE_UPLOAD_TTL_SECONDS"),
    to_int
  )
  |> maybe_put_env.(
    :download_ttl_seconds,
    System.get_env("PLUGIN_STORAGE_DOWNLOAD_TTL_SECONDS"),
    to_int
  )
  |> maybe_put_env.(:max_upload_bytes, System.get_env("PLUGIN_STORAGE_MAX_UPLOAD_BYTES"), to_int)
  |> maybe_put_env_simple.(:jetstream_bucket, plugin_storage_bucket)
  |> maybe_put_env.(
    :jetstream_max_bucket_size,
    System.get_env("PLUGIN_STORAGE_JS_MAX_BUCKET_BYTES"),
    to_int
  )
  |> maybe_put_env.(
    :jetstream_max_chunk_size,
    System.get_env("PLUGIN_STORAGE_JS_MAX_CHUNK_BYTES"),
    to_int
  )
  |> maybe_put_env.(:jetstream_replicas, System.get_env("PLUGIN_STORAGE_JS_REPLICAS"), to_int)
  |> maybe_put_env.(
    :jetstream_storage,
    System.get_env("PLUGIN_STORAGE_JS_STORAGE"),
    normalize_js_storage
  )
  |> maybe_put_env.(
    :jetstream_ttl_seconds,
    System.get_env("PLUGIN_STORAGE_JS_TTL_SECONDS"),
    to_int
  )
  |> maybe_put_env_simple.(:signing_secret, plugin_storage_signing_secret)

god_view_runtime_graph_refresh_ms =
  case to_int.(System.get_env("SERVICERADAR_GOD_VIEW_RUNTIME_GRAPH_REFRESH_MS", "30000")) do
    value when is_integer(value) and value > 0 -> value
    _ -> 30_000
  end

god_view_runtime_graph_auto_refresh =
  case to_bool.(System.get_env("SERVICERADAR_GOD_VIEW_RUNTIME_GRAPH_AUTO_REFRESH", "true")) do
    nil -> true
    value -> value
  end

camera_relay_browser_stream_timeout_ms =
  case to_int.(System.get_env("CAMERA_RELAY_BROWSER_STREAM_TIMEOUT_MS", "86400000")) do
    value when is_integer(value) and value > 0 -> value
    _other -> 86_400_000
  end

config :serviceradar_core,
  device_enrichment_rules_dir:
    System.get_env("DEVICE_ENRICHMENT_RULES_DIR", "/var/lib/serviceradar/rules/device-enrichment")

config :serviceradar_web_ng, :god_view_enabled, god_view_enabled

config :serviceradar_web_ng,
       :managed_device_limit,
       to_int.(System.get_env("SERVICERADAR_MANAGED_DEVICE_LIMIT"))

config :serviceradar_web_ng, :runtime_capabilities, runtime_capabilities

config :serviceradar_web_ng,
  camera_relay_browser_stream_timeout_ms: camera_relay_browser_stream_timeout_ms

config :serviceradar_web_ng,
  device_enrichment_rules_dir:
    System.get_env("DEVICE_ENRICHMENT_RULES_DIR", "/var/lib/serviceradar/rules/device-enrichment")

config :serviceradar_web_ng,
  god_view_runtime_graph_refresh_ms: god_view_runtime_graph_refresh_ms,
  god_view_runtime_graph_auto_refresh: god_view_runtime_graph_auto_refresh

if plugin_storage_overrides != [] do
  config :serviceradar_web_ng,
         :plugin_storage,
         Keyword.merge(plugin_storage_defaults, plugin_storage_overrides)
end

plugin_verification_overrides =
  []
  |> maybe_put_env.(
    :require_gpg_for_github,
    System.get_env("PLUGIN_REQUIRE_GPG_FOR_GITHUB"),
    to_bool
  )
  |> maybe_put_env.(
    :allow_unsigned_uploads,
    System.get_env("PLUGIN_ALLOW_UNSIGNED_UPLOADS"),
    to_bool
  )
  |> maybe_put_env.(
    :trusted_github_signers,
    System.get_env("PLUGIN_TRUSTED_GITHUB_SIGNERS"),
    to_csv_list
  )
  |> maybe_put_env.(
    :trusted_github_owners,
    System.get_env("PLUGIN_TRUSTED_GITHUB_OWNERS"),
    to_csv_list
  )
  |> maybe_put_env.(
    :trusted_github_repositories,
    System.get_env("PLUGIN_TRUSTED_GITHUB_REPOSITORIES"),
    to_csv_list
  )
  |> maybe_put_env.(
    :trusted_upload_signing_keys,
    System.get_env("PLUGIN_TRUSTED_UPLOAD_SIGNING_KEYS"),
    to_csv_map
  )

if plugin_verification_overrides != [] do
  config :serviceradar_web_ng,
         :plugin_verification,
         Keyword.merge(plugin_verification_defaults, plugin_verification_overrides)
end

client_ip_overrides =
  []
  |> maybe_put_env.(
    :trust_x_forwarded_for,
    System.get_env("SERVICERADAR_TRUST_X_FORWARDED_FOR"),
    to_bool
  )
  |> maybe_put_env.(
    :trusted_proxy_cidrs,
    System.get_env("SERVICERADAR_TRUSTED_PROXY_CIDRS"),
    to_csv_list
  )

if client_ip_overrides != [] do
  config :serviceradar_web_ng, :client_ip, Keyword.merge(client_ip_defaults, client_ip_overrides)
end

# libcluster configuration for ERTS cluster formation
# Strategy selection: kubernetes, epmd, dns, or gossip (future)
hosted_cluster_contract =
  case System.get_env("SERVICERADAR_HOSTED_CLUSTER_CONTRACT") do
    nil ->
      %{}

    raw ->
      case Jason.decode(raw) do
        {:ok, contract} when is_map(contract) -> contract
        _ -> %{}
      end
  end

cluster_strategy =
  get_in(hosted_cluster_contract, ["strategy"]) || System.get_env("CLUSTER_STRATEGY", "epmd")

cluster_enabled =
  case get_in(hosted_cluster_contract, ["enabled"]) do
    value when is_boolean(value) -> value
    _ -> System.get_env("CLUSTER_ENABLED", "false") in ~w(true 1 yes)
  end

# web-ng participates in the cluster but does NOT run ClusterSupervisor/ClusterHealth
# Those are managed by core-elx (the cluster coordinator)
cluster_coordinator =
  System.get_env("SERVICERADAR_CLUSTER_COORDINATOR", "false") in ~w(true 1 yes)

config :serviceradar_core,
  cluster_enabled: cluster_enabled,
  cluster_coordinator: cluster_coordinator

if cluster_enabled do
  topologies =
    case cluster_strategy do
      "kubernetes" ->
        # Kubernetes DNS-based discovery (production)
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
        # DNSPoll strategy for bare metal with service discovery
        dns_query =
          get_in(hosted_cluster_contract, ["web", "dns_query"]) ||
            System.get_env("CLUSTER_DNS_QUERY", "")

        node_basename =
          get_in(hosted_cluster_contract, ["web", "node_basename"]) ||
            System.get_env("CLUSTER_NODE_BASENAME", "serviceradar_web_ng")

        core_dns_query =
          get_in(hosted_cluster_contract, ["web", "core_dns_query"]) ||
            System.get_env("CLUSTER_CORE_DNS_QUERY", "")

        core_node_basename =
          get_in(hosted_cluster_contract, ["web", "core_node_basename"]) ||
            System.get_env("CLUSTER_CORE_NODE_BASENAME", "serviceradar_core")

        gateway_dns_query =
          get_in(hosted_cluster_contract, ["web", "gateway_dns_query"]) ||
            System.get_env("CLUSTER_GATEWAY_DNS_QUERY", "")

        gateway_node_basename =
          get_in(hosted_cluster_contract, ["web", "gateway_node_basename"]) ||
            System.get_env("CLUSTER_GATEWAY_NODE_BASENAME", "serviceradar_agent_gateway")

        maybe_add_dns_topology = fn topologies, name, query, basename ->
          if query in [nil, ""] do
            topologies
          else
            topologies ++
              [
                {name,
                 [
                   strategy: Cluster.Strategy.DNSPoll,
                   config: [
                     polling_interval: 5_000,
                     query: query,
                     node_basename: basename
                   ]
                 ]}
              ]
          end
        end

        []
        |> maybe_add_dns_topology.(:serviceradar, dns_query, node_basename)
        |> maybe_add_dns_topology.(:serviceradar_core, core_dns_query, core_node_basename)
        |> maybe_add_dns_topology.(
          :serviceradar_gateway,
          gateway_dns_query,
          gateway_node_basename
        )

      "epmd" ->
        # EPMD strategy for development and static bare metal
        hosts_str = System.get_env("CLUSTER_HOSTS", "")

        hosts =
          hosts_str
          |> String.split(",", trim: true)
          |> Enum.map(&String.trim/1)
          |> Enum.map(&String.to_atom/1)

        if hosts == [] do
          []
        else
          [
            serviceradar: [
              strategy: Cluster.Strategy.Epmd,
              config: [hosts: hosts]
            ]
          ]
        end

      "gossip" ->
        # Gossip strategy for large-scale deployments (future)
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

  if topologies != [] do
    config :libcluster, topologies: topologies
  end
end

if config_env() != :test do
  admin_username = System.get_env("ADMIN_BASIC_AUTH_USERNAME")
  admin_password = System.get_env("ADMIN_BASIC_AUTH_PASSWORD")

  if admin_username && admin_password do
    config :serviceradar_web_ng, :admin_basic_auth,
      username: admin_username,
      password: admin_password
  end

  oban_enabled =
    System.get_env("SERVICERADAR_WEB_NG_OBAN_ENABLED", "true") in ~w(true 1 yes)

  parse_queue_limit = fn env_names, default ->
    env_names
    |> List.wrap()
    |> Enum.find_value(fn env_name ->
      case System.get_env(env_name) do
        nil -> nil
        "" -> nil
        value -> value
      end
    end)
    |> case do
      nil ->
        default

      value ->
        case Integer.parse(value) do
          {int, ""} when int >= 0 -> int
          _ -> default
        end
    end
  end

  maybe_queue = fn queues, queue, limit ->
    if limit > 0 do
      Keyword.put(queues, queue, limit)
    else
      queues
    end
  end

  # web-ng should not execute external/network maintenance jobs (GeoLite/ipinfo downloads,
  # enrichment refresh, threat intel refresh, etc.). core-elx owns those.
  oban_maintenance_queue_limit =
    parse_queue_limit.(["WEB_NG_OBAN_QUEUE_MAINTENANCE", "OBAN_MAINTENANCE_QUEUE_LIMIT"], 0)

  oban_node = System.get_env("OBAN_NODE")

  oban_notifier =
    case "WEB_NG_OBAN_NOTIFIER" |> System.get_env("postgres") |> String.downcase() do
      value when value in ["pg", "process_group", "process-groups"] -> Oban.Notifiers.PG
      _ -> Oban.Notifiers.Postgres
    end

  # web-ng does not run scheduled jobs or acquire the Oban peer lock; core-elx remains
  # the scheduler leader. It can still process runtime jobs within explicit budgets.
  queues =
    []
    |> maybe_queue.(
      :default,
      parse_queue_limit.(["WEB_NG_OBAN_QUEUE_DEFAULT", "OBAN_DEFAULT_QUEUE_LIMIT"], 10)
    )
    |> maybe_queue.(:alerts, parse_queue_limit.("WEB_NG_OBAN_QUEUE_ALERTS", 5))
    |> maybe_queue.(
      :service_checks,
      parse_queue_limit.("WEB_NG_OBAN_QUEUE_SERVICE_CHECKS", 10)
    )
    |> maybe_queue.(:notifications, parse_queue_limit.("WEB_NG_OBAN_QUEUE_NOTIFICATIONS", 5))
    |> maybe_queue.(:onboarding, parse_queue_limit.("WEB_NG_OBAN_QUEUE_ONBOARDING", 3))
    |> maybe_queue.(:events, parse_queue_limit.("WEB_NG_OBAN_QUEUE_EVENTS", 10))
    |> maybe_queue.(:sweeps, parse_queue_limit.("WEB_NG_OBAN_QUEUE_SWEEPS", 20))
    |> maybe_queue.(:edge, parse_queue_limit.("WEB_NG_OBAN_QUEUE_EDGE", 10))
    |> maybe_queue.(:integrations, parse_queue_limit.("WEB_NG_OBAN_QUEUE_INTEGRATIONS", 5))
    |> maybe_queue.(:maintenance, oban_maintenance_queue_limit)

  oban_config = [
    repo: ServiceRadar.Repo,
    prefix: "platform",
    queues: queues,
    notifier: oban_notifier,
    plugins: [
      {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 7}
      # No Cron plugin - core-elx handles all scheduled jobs
    ],
    # Avoid acquiring the Oban peer lock so core-elx remains the scheduler leader.
    peer: false
  ]

  oban_config =
    if oban_node do
      Keyword.put(oban_config, :node, oban_node)
    else
      oban_config
    end

  config :serviceradar_core, Oban, oban_config
  config :serviceradar_core, :log_promotion_consumer_enabled, false
  config :serviceradar_core, :oban_enabled, oban_enabled
  config :serviceradar_core, :start_ash_oban_scheduler, false
end

# Phoenix React Server production configuration
# In production, use the bundled server.js created by mix phx.react.bun.bundle
if config_env() == :prod do
  config :phoenix_react_server, Phoenix.React.Runtime.Bun,
    cmd: System.find_executable("bun"),
    server_js: Path.expand("../priv/react/server.js", __DIR__),
    port: String.to_integer(System.get_env("REACT_RENDER_PORT", "12666")),
    env: :prod
end

if config_env() == :prod do
  database_url = System.get_env("DATABASE_URL")

  cnpg_host = System.get_env("CNPG_HOST")
  cnpg_port = String.to_integer(System.get_env("CNPG_PORT", "5432"))
  cnpg_database = System.get_env("CNPG_DATABASE", "serviceradar")
  cnpg_username = System.get_env("CNPG_USERNAME", "serviceradar")

  cnpg_password =
    case System.get_env("CNPG_PASSWORD_FILE") do
      nil ->
        System.get_env("CNPG_PASSWORD", "serviceradar")

      path ->
        case File.read(path) do
          {:ok, value} ->
            value = String.trim(value)
            if value == "", do: System.get_env("CNPG_PASSWORD", "serviceradar"), else: value

          {:error, _} ->
            System.get_env("CNPG_PASSWORD", "serviceradar")
        end
    end

  cnpg_ssl_mode = System.get_env("CNPG_SSL_MODE", "disable")
  cnpg_ssl_enabled = cnpg_ssl_mode != "disable"
  cnpg_tls_server_name = System.get_env("CNPG_TLS_SERVER_NAME", cnpg_host || "")

  cnpg_cert_dir = System.get_env("CNPG_CERT_DIR", "")

  cnpg_ca_file =
    System.get_env(
      "CNPG_CA_FILE",
      if(cnpg_cert_dir == "", do: "", else: Path.join(cnpg_cert_dir, "root.pem"))
    )

  cnpg_cert_file =
    System.get_env(
      "CNPG_CERT_FILE",
      if(cnpg_cert_dir == "", do: "", else: Path.join(cnpg_cert_dir, "workstation.pem"))
    )

  cnpg_key_file =
    System.get_env(
      "CNPG_KEY_FILE",
      if(cnpg_cert_dir == "", do: "", else: Path.join(cnpg_cert_dir, "workstation-key.pem"))
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

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    read_secret_env.("SECRET_KEY_BASE", "SECRET_KEY_BASE_FILE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "localhost"

  dev_routes =
    case System.get_env("SERVICERADAR_DEV_ROUTES") do
      "true" -> true
      "1" -> true
      "yes" -> true
      _ -> false
    end

  local_mailer_requested =
    case System.get_env("SERVICERADAR_LOCAL_MAILER") do
      "true" -> true
      "1" -> true
      "yes" -> true
      _ -> false
    end

  local_mailer =
    if local_mailer_requested and cluster_enabled do
      require Logger

      Logger.warning(
        "SERVICERADAR_LOCAL_MAILER is disabled because clustered web-ng replicas cannot share local Swoosh storage safely"
      )

      false
    else
      local_mailer_requested
    end

  # Security mode for edge onboarding: "mtls" for docker deployments, "spire" for k8s
  security_mode =
    case System.get_env("SERVICERADAR_SECURITY_MODE") do
      "mtls" -> "mtls"
      "spire" -> "spire"
      # Default to mTLS for docker deployments
      _ -> "mtls"
    end

  check_origin =
    case System.get_env("PHX_CHECK_ORIGIN") do
      nil -> :conn
      "" -> :conn
      "false" -> false
      "true" -> :conn
      value -> value |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
    end

  # Token signing secret for AshAuthentication JWT tokens
  # Falls back to SECRET_KEY_BASE if not explicitly set
  token_signing_secret =
    System.get_env("TOKEN_SIGNING_SECRET") || secret_key_base

  session_idle_seconds =
    "SERVICERADAR_SESSION_IDLE_TIMEOUT_SECONDS"
    |> System.get_env()
    |> to_int.()

  session_absolute_seconds =
    "SERVICERADAR_SESSION_ABSOLUTE_TIMEOUT_SECONDS"
    |> System.get_env()
    |> to_int.()

  session_config = Application.get_env(:serviceradar_web_ng, :session, [])

  session_config =
    if is_integer(session_idle_seconds) and session_idle_seconds > 0 do
      Keyword.put(session_config, :idle_timeout_seconds, session_idle_seconds)
    else
      session_config
    end

  session_config =
    if is_integer(session_absolute_seconds) and session_absolute_seconds > 0 do
      Keyword.put(session_config, :absolute_timeout_seconds, session_absolute_seconds)
    else
      session_config
    end

  gateway_addr = System.get_env("SERVICERADAR_GATEWAY_ADDR")
  gateway_server_name = System.get_env("SERVICERADAR_GATEWAY_SERVER_NAME")
  agent_release_public_key = System.get_env("SERVICERADAR_AGENT_RELEASE_PUBLIC_KEY")
  onboarding_token_private_key = System.get_env("SERVICERADAR_ONBOARDING_TOKEN_PRIVATE_KEY")
  onboarding_token_public_key_env = System.get_env("SERVICERADAR_ONBOARDING_TOKEN_PUBLIC_KEY")

  decode_ed25519_key = fn raw_key ->
    raw_key = String.trim(raw_key)

    decoders = [
      fn -> Base.decode64(raw_key) end,
      fn -> Base.url_decode64(raw_key, padding: false) end,
      fn -> Base.decode16(raw_key, case: :mixed) end
    ]

    Enum.reduce_while(decoders, {:error, :invalid_key}, fn decoder, _acc ->
      case decoder.() do
        {:ok, decoded} -> {:halt, {:ok, decoded}}
        :error -> {:cont, {:error, :invalid_key}}
      end
    end)
  end

  onboarding_token_public_key =
    cond do
      is_binary(onboarding_token_public_key_env) and
          String.trim(onboarding_token_public_key_env) != "" ->
        String.trim(onboarding_token_public_key_env)

      is_binary(onboarding_token_private_key) and String.trim(onboarding_token_private_key) != "" ->
        with {:ok, key_bytes} <- decode_ed25519_key.(onboarding_token_private_key),
             seed when byte_size(seed) in [32, 64] <-
               if(byte_size(key_bytes) == 64, do: binary_part(key_bytes, 0, 32), else: key_bytes),
             {public_key, _private_key} <- :crypto.generate_key(:eddsa, :ed25519, seed) do
          Base.encode64(public_key)
        else
          _ -> nil
        end

      true ->
        nil
    end

  # Configure ServiceRadar.Repo from serviceradar_core
  repo_config =
    [
      url: repo_url,
      ssl: if(cnpg_ssl_enabled, do: cnpg_ssl_opts, else: false),
      pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
      queue_target: String.to_integer(System.get_env("DATABASE_QUEUE_TARGET_MS") || "2000"),
      queue_interval: String.to_integer(System.get_env("DATABASE_QUEUE_INTERVAL_MS") || "2000"),
      timeout: String.to_integer(System.get_env("DATABASE_TIMEOUT_MS") || "120000"),
      pool_timeout: String.to_integer(System.get_env("DATABASE_POOL_TIMEOUT_MS") || "120000"),
      socket_options: maybe_ipv6,
      parameters: [search_path: System.get_env("CNPG_SEARCH_PATH", "platform, public, ag_catalog")],
      types: ServiceRadar.PostgresTypes
    ]

  repo_config =
    case System.get_env("DATABASE_PREPARE", "") do
      "unnamed" -> Keyword.put(repo_config, :prepare, :unnamed)
      "named" -> Keyword.put(repo_config, :prepare, :named)
      _ -> repo_config
    end

  config :serviceradar_core, ServiceRadar.Repo, repo_config

  # Guardian JWT signing secret (same as token_signing_secret for consistency)
  config :serviceradar_web_ng, ServiceRadarWebNG.Auth.Guardian, secret_key: token_signing_secret
  config :serviceradar_web_ng, :base_url, "https://#{host}"
  config :serviceradar_web_ng, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")
  config :serviceradar_web_ng, :session, session_config
  config :serviceradar_web_ng, :token_signing_secret, token_signing_secret
  config :serviceradar_web_ng, dev_routes: dev_routes
  config :serviceradar_web_ng, local_mailer: local_mailer
  config :serviceradar_web_ng, security_mode: security_mode

  if is_binary(gateway_addr) and String.trim(gateway_addr) != "" do
    config :serviceradar_web_ng, :gateway_addr, String.trim(gateway_addr)
  end

  if is_binary(gateway_server_name) and String.trim(gateway_server_name) != "" do
    config :serviceradar_web_ng, :gateway_server_name, String.trim(gateway_server_name)
  end

  if is_binary(agent_release_public_key) and String.trim(agent_release_public_key) != "" do
    trimmed_agent_release_public_key = String.trim(agent_release_public_key)
    config :serviceradar_core, :agent_release_public_key, trimmed_agent_release_public_key

    config :serviceradar_web_ng, :agent_release_public_key, trimmed_agent_release_public_key
  end

  if is_binary(onboarding_token_private_key) and String.trim(onboarding_token_private_key) != "" do
    config :serviceradar_web_ng,
           :onboarding_token_private_key,
           String.trim(onboarding_token_private_key)
  end

  if is_binary(onboarding_token_public_key) and String.trim(onboarding_token_public_key) != "" do
    config :serviceradar_web_ng,
           :onboarding_token_public_key,
           String.trim(onboarding_token_public_key)
  end

  nats_url = System.get_env("NATS_URL") || System.get_env("SERVICERADAR_NATS_URL")

  if is_binary(nats_url) and String.trim(nats_url) != "" do
    config :serviceradar_web_ng, :nats_url, String.trim(nats_url)
  end

  core_address = System.get_env("CORE_ADDRESS") || System.get_env("SERVICERADAR_CORE_ADDRESS")

  if is_binary(core_address) and String.trim(core_address) != "" do
    config :serviceradar_web_ng, :core_address, String.trim(core_address)
  end

  # Control Plane JWT configuration
  # Used to validate JWTs issued by the SaaS Control Plane.
  # In OSS/single-deployment setups, this can be left unconfigured.
  control_plane_public_key = System.get_env("CONTROL_PLANE_PUBLIC_KEY")
  control_plane_public_key_file = System.get_env("CONTROL_PLANE_PUBLIC_KEY_FILE")

  control_plane_jwt_config =
    cond do
      control_plane_public_key ->
        [public_key: control_plane_public_key]

      control_plane_public_key_file ->
        [public_key_file: control_plane_public_key_file]

      true ->
        []
    end

  if control_plane_jwt_config != [] do
    control_plane_jwt_config =
      control_plane_jwt_config
      |> Keyword.put(
        :issuer,
        System.get_env("CONTROL_PLANE_JWT_ISSUER", "serviceradar-control-plane")
      )
      |> Keyword.put(
        :audience,
        System.get_env("CONTROL_PLANE_JWT_AUDIENCE", "serviceradar-deployment")
      )

    config :serviceradar_web_ng, ServiceRadarWebNG.Auth.ControlPlaneJWT, control_plane_jwt_config
  end

  spiffe_mode =
    case System.get_env("SPIFFE_MODE", "filesystem") do
      "workload_api" -> :workload_api
      _ -> :filesystem
    end

  spiffe_bundle_path = System.get_env("SPIFFE_TRUST_BUNDLE_PATH")

  # Datasvc gRPC client configuration for KV store access
  # Used for fetching component templates and other KV data
  datasvc_address = System.get_env("DATASVC_ADDRESS")

  config :serviceradar_core, :spiffe,
    mode: spiffe_mode,
    trust_domain: System.get_env("SPIFFE_TRUST_DOMAIN", "serviceradar.local"),
    cert_dir: System.get_env("SPIFFE_CERT_DIR", "/etc/serviceradar/certs"),
    workload_api_socket: System.get_env("SPIFFE_WORKLOAD_API_SOCKET", "unix:///run/spire/sockets/agent.sock"),
    trust_bundle_path: spiffe_bundle_path

  if datasvc_address do
    datasvc_cert_dir = System.get_env("DATASVC_CERT_DIR", "/etc/serviceradar/certs")
    datasvc_server_name = System.get_env("DATASVC_SERVER_NAME", "datasvc.serviceradar")
    datasvc_sec_mode = System.get_env("DATASVC_SEC_MODE")
    datasvc_ssl = System.get_env("DATASVC_SSL", "false") in ~w(true 1 yes)

    datasvc_sec_mode =
      case datasvc_sec_mode && String.downcase(String.trim(datasvc_sec_mode)) do
        "spiffe" -> "spiffe"
        "mtls" -> "mtls"
        "tls" -> "tls"
        "plaintext" -> "plaintext"
        "none" -> "plaintext"
        _ -> if datasvc_ssl, do: "mtls", else: "plaintext"
      end

    tls_config =
      case datasvc_sec_mode do
        "spiffe" ->
          spiffe_cert_dir = System.get_env("DATASVC_SPIFFE_CERT_DIR")
          spiffe_opts = if spiffe_cert_dir, do: [cert_dir: spiffe_cert_dir], else: []

          case ServiceRadar.SPIFFE.client_ssl_opts(spiffe_opts) do
            {:ok, ssl_opts} ->
              ssl_opts

            {:error, reason} ->
              Logger.error("SPIFFE mTLS not available for datasvc: #{inspect(reason)}")
              nil
          end

        "mtls" ->
          if File.exists?(datasvc_cert_dir) do
            [
              cacertfile: Path.join(datasvc_cert_dir, "root.pem"),
              certfile: Path.join(datasvc_cert_dir, "web.pem"),
              keyfile: Path.join(datasvc_cert_dir, "web-key.pem"),
              server_name_indication: String.to_charlist(datasvc_server_name)
            ]
          end

        "tls" ->
          []

        _ ->
          nil
      end

    datasvc_config = [
      address: datasvc_address,
      timeout: String.to_integer(System.get_env("DATASVC_TIMEOUT", "5000"))
    ]

    datasvc_config =
      if tls_config do
        Keyword.put(datasvc_config, :tls, tls_config)
      else
        datasvc_config
      end

    config :datasvc, :datasvc, datasvc_config
  end

  mailer_adapter_env =
    System.get_env("SERVICERADAR_CORE_MAILER_ADAPTER") ||
      System.get_env("SERVICERADAR_MAILER_ADAPTER")

  smtp_relay_host = System.get_env("SMTP_RELAY_HOST")
  smtp_relay_port = to_int.(System.get_env("SMTP_RELAY_PORT")) || 25
  smtp_relay_hostname = System.get_env("SMTP_RELAY_HOSTNAME") || host
  smtp_relay_username = System.get_env("SMTP_RELAY_USERNAME")
  smtp_relay_password = System.get_env("SMTP_RELAY_PASSWORD")
  mail_from_name = System.get_env("SERVICERADAR_MAIL_FROM_NAME") || "ServiceRadar"
  mail_from_email = System.get_env("SERVICERADAR_MAIL_FROM_EMAIL") || "noreply@serviceradar.cloud"

  smtp_relay_auth =
    case "SMTP_RELAY_AUTH"
         |> System.get_env("if_available")
         |> String.trim()
         |> String.downcase() do
      "always" -> :always
      "never" -> :never
      _ -> :if_available
    end

  smtp_relay_tls =
    case "SMTP_RELAY_TLS"
         |> System.get_env("if_available")
         |> String.trim()
         |> String.downcase() do
      "always" -> :always
      "never" -> :never
      _ -> :if_available
    end

  smtp_relay_ssl = to_bool.(System.get_env("SMTP_RELAY_SSL")) || false

  mailer_adapter =
    case String.trim(mailer_adapter_env || "") do
      "" ->
        if local_mailer do
          Local
        else
          Swoosh.Adapters.Test
        end

      "local" ->
        Local

      adapter ->
        if String.contains?(adapter, ".") do
          adapter
          |> String.split(".")
          |> Enum.map(&String.to_atom/1)
          |> Module.concat()
        else
          Module.concat(Swoosh.Adapters, Macro.camelize(adapter))
        end
    end

  mailer_config = [adapter: mailer_adapter]

  mailer_config =
    if mailer_adapter == Local or is_nil(smtp_relay_host) do
      mailer_config
    else
      mailer_config
      |> Keyword.put(:relay, smtp_relay_host)
      |> Keyword.put(:port, smtp_relay_port)
      |> Keyword.put(:auth, smtp_relay_auth)
      |> Keyword.put(:tls, smtp_relay_tls)
      |> Keyword.put(:ssl, smtp_relay_ssl)
      |> Keyword.put(:hostname, smtp_relay_hostname)
      |> Keyword.put(:from_name, mail_from_name)
      |> Keyword.put(:from_email, mail_from_email)
      |> maybe_put_mailer_credential.(:username, smtp_relay_username)
      |> maybe_put_mailer_credential.(:password, smtp_relay_password)
    end

  config :serviceradar_core, ServiceRadar.Mailer, mailer_config

  config :serviceradar_web_ng, ServiceRadarWebNG.Mailer, mailer_config

  if local_mailer or mailer_adapter == Local do
    config :swoosh, :api_client, false
    config :swoosh, local: true
  else
    config :swoosh, local: false
  end

  config :serviceradar_web_ng, ServiceRadarWebNGWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Bind on all IPv4 interfaces for docker bridge networking.
      ip: {0, 0, 0, 0},
      port: String.to_integer(System.get_env("PORT", "4000"))
    ],
    check_origin: check_origin,
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :serviceradar_web_ng, ServiceRadarWebNGWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :serviceradar_web_ng, ServiceRadarWebNGWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Here is an example configuration for Mailgun:
  #
  #     config :serviceradar_web_ng, ServiceRadarWebNG.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: System.get_env("MAILGUN_API_KEY"),
  #       domain: System.get_env("MAILGUN_DOMAIN")
  #
  # Most non-SMTP adapters require an API client. Swoosh supports Req, Hackney,
  # and Finch out-of-the-box. This configuration is typically done at
  # compile-time in your config/prod.exs:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Req
  #
  # See https://hexdocs.pm/swoosh/Swoosh.html#module-installation for details.
end
