import Config

# Runtime configuration for production deployments.
# This file is executed at runtime, not compile time.

alias Cluster.Strategy.DNSPoll
alias Cluster.Strategy.Kubernetes.DNS
alias Geolix.Adapter.MMDB2
alias ServiceRadar.Automation.Ansible.FileCallbackResponsePolicyProvider
alias ServiceRadar.Automation.CallbackGrants.RuntimeConfig
alias ServiceRadar.Edge.RemoteAccessSSHCACommandSigner
alias ServiceRadar.EventWriter.Config
alias ServiceRadar.EventWriter.Processors.AnalyticsSignals
alias ServiceRadar.EventWriter.Processors.Flows
alias ServiceRadar.EventWriter.Processors.PowerDNS
alias ServiceRadar.Jobs.RefreshTraceSummariesWorker
alias ServiceRadar.Jobs.RootSpanRatioWorker
alias ServiceRadar.Notifications.ContinuationWorker, as: NotificationContinuationWorker
alias ServiceRadar.Notifications.DeliveryRetentionWorker, as: NotificationRetentionWorker
alias ServiceRadar.Notifications.DispatchSchedule
alias ServiceRadar.Notifications.PluginTarget, as: NotificationPluginTarget
alias ServiceRadar.Notifications.ReceiptWorker, as: NotificationReceiptWorker
alias ServiceRadar.Notifications.SilenceExpiryWorker, as: NotificationSilenceExpiryWorker
alias ServiceRadar.Observability.CapacityForecasting.Worker, as: CapacityForecastingWorker
alias ServiceRadar.Observability.DataRetentionWorker
alias ServiceRadar.Observability.ProductionSchedule
alias ServiceRadar.Observability.SeasonalDisposition.Worker, as: SeasonalDispositionWorker

callback_deployment =
  RuntimeConfig.callback_deployment_config!(%{
    enabled: System.get_env("SERVICERADAR_AUTOMATION_CALLBACKS_ENABLED", "false"),
    credential_type_id: System.get_env("SERVICERADAR_AUTOMATION_CALLBACK_AWX_CREDENTIAL_TYPE_ID"),
    organization_id: System.get_env("SERVICERADAR_AUTOMATION_CALLBACK_AWX_ORGANIZATION_ID"),
    injector_digest: System.get_env("SERVICERADAR_AUTOMATION_CALLBACK_AWX_INJECTOR_DIGEST"),
    response_policy_file: System.get_env("SERVICERADAR_AUTOMATION_CALLBACK_RESPONSE_POLICY_FILE")
  })

if is_map(callback_deployment) do
  # Automation callback bearer verification is file-only: never accept HMAC
  # key material directly from an environment variable where process
  # inspection can expose it. An enabled deployment fails boot when any
  # custody input is missing or malformed.
  verifier_config =
    "SERVICERADAR_AUTOMATION_CALLBACK_HMAC_KEYRING_FILE"
    |> System.get_env()
    |> RuntimeConfig.load_verifier_file!()

  envelope_key =
    "SERVICERADAR_AUTOMATION_CALLBACK_ENVELOPE_KEY_FILE"
    |> System.get_env()
    |> RuntimeConfig.load_envelope_key_file!()

  callback_origin =
    case System.get_env("SERVICERADAR_AUTOMATION_CALLBACK_ORIGIN") do
      origin when is_binary(origin) and origin != "" ->
        case RuntimeConfig.canonical_callback_origin(origin) do
          {:ok, canonical_origin} -> canonical_origin
          {:error, _reason} -> raise "invalid ServiceRadar automation callback origin"
        end

      _ ->
        raise "ServiceRadar automation callback origin is required"
    end

  config :serviceradar_core,
         FileCallbackResponsePolicyProvider,
         callback_deployment.response_policy_provider_config

  config :serviceradar_core,
         :automation_callback_awx_credential_contract,
         callback_deployment.credential_contract

  config :serviceradar_core,
         :automation_callback_response_policy_provider,
         callback_deployment.response_policy_provider

  config :serviceradar_core,
    automation_callback_grants: [verifier_config: verifier_config],
    automation_launch_envelope_key: envelope_key,
    automation_launch_envelope_key_id:
      System.get_env("SERVICERADAR_AUTOMATION_CALLBACK_ENVELOPE_KEY_ID", "current"),
    automation_callback_origin: callback_origin
end

# Netprobe native add-on package — signed artifact refs for the package seeder.
# native-addons.yml emits per-arch object_key/sha256/signature refs in its import index;
# deployments pass them here (as JSON) + the published version so
# NetprobeAddonPackageSeeder can approve an assignable package. Without artifacts the
# seeder stages the manifest version (visible, not assignable); version/oci refs are only
# set when their env vars are present (version otherwise defaults to the in-image manifest).

netprobe_addon_artifacts =
  case System.get_env("SERVICERADAR_NETPROBE_ADDON_ARTIFACTS") do
    json when is_binary(json) and json != "" ->
      case Jason.decode(json) do
        {:ok, %{} = map} -> map
        _ -> %{}
      end

    _ ->
      %{}
  end

netprobe_addon_config = [artifacts: netprobe_addon_artifacts]

netprobe_addon_config =
  case System.get_env("SERVICERADAR_NETPROBE_ADDON_VERSION") do
    v when is_binary(v) and v != "" -> Keyword.put(netprobe_addon_config, :version, v)
    _ -> netprobe_addon_config
  end

netprobe_addon_config =
  case System.get_env("SERVICERADAR_NETPROBE_ADDON_OCI_REF") do
    v when is_binary(v) and v != "" -> Keyword.put(netprobe_addon_config, :source_oci_ref, v)
    _ -> netprobe_addon_config
  end

netprobe_addon_config =
  case System.get_env("SERVICERADAR_NETPROBE_ADDON_OCI_DIGEST") do
    v when is_binary(v) and v != "" -> Keyword.put(netprobe_addon_config, :source_oci_digest, v)
    _ -> netprobe_addon_config
  end

# OTEL collector native add-on package — signed artifact refs for the package seeder.
# native-addons.yml emits per-arch object_key/sha256/signature refs in its import index;
# deployments pass them here (as JSON) + the published version so
# OtelCollectorAddonPackageSeeder can approve an assignable package. Without artifacts the
# seeder stages the manifest version (visible, not assignable); version/oci refs are only
# set when their env vars are present (version otherwise defaults to the in-image manifest).

otel_collector_addon_artifacts =
  case System.get_env("SERVICERADAR_OTEL_COLLECTOR_ADDON_ARTIFACTS") do
    json when is_binary(json) and json != "" ->
      case Jason.decode(json) do
        {:ok, %{} = map} -> map
        _ -> %{}
      end

    _ ->
      %{}
  end

otel_collector_addon_config = [artifacts: otel_collector_addon_artifacts]

otel_collector_addon_config =
  case System.get_env("SERVICERADAR_OTEL_COLLECTOR_ADDON_VERSION") do
    v when is_binary(v) and v != "" -> Keyword.put(otel_collector_addon_config, :version, v)
    _ -> otel_collector_addon_config
  end

otel_collector_addon_config =
  case System.get_env("SERVICERADAR_OTEL_COLLECTOR_ADDON_OCI_REF") do
    v when is_binary(v) and v != "" ->
      Keyword.put(otel_collector_addon_config, :source_oci_ref, v)

    _ ->
      otel_collector_addon_config
  end

otel_collector_addon_config =
  case System.get_env("SERVICERADAR_OTEL_COLLECTOR_ADDON_OCI_DIGEST") do
    v when is_binary(v) and v != "" ->
      Keyword.put(otel_collector_addon_config, :source_oci_digest, v)

    _ ->
      otel_collector_addon_config
  end

# GeoLite2 MMDB configuration (all environments)
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

remote_access_ssh_certificate_policy =
  case System.get_env("SERVICERADAR_REMOTE_ACCESS_SSH_CERTIFICATE_POLICY_JSON") do
    nil ->
      case System.get_env("SERVICERADAR_REMOTE_ACCESS_SSH_CERTIFICATE_POLICY_FILE") do
        nil -> %{}
        "" -> %{}
        path -> path |> File.read!() |> Jason.decode!()
      end

    "" ->
      %{}

    raw ->
      Jason.decode!(raw)
  end

remote_access_ssh_ca_signer_enabled =
  System.get_env("SERVICERADAR_REMOTE_ACCESS_SSH_CA_SIGNER_ENABLED", "false") in ~w(true 1 yes)

remote_access_desktop_rdp_enabled =
  System.get_env("SERVICERADAR_REMOTE_ACCESS_DESKTOP_RDP_ENABLED", "false") in ~w(true 1 yes)

remote_access_ssh_ca_signer_args =
  case System.get_env("SERVICERADAR_REMOTE_ACCESS_SSH_CA_SIGNER_ARGS_JSON") do
    nil ->
      []

    "" ->
      []

    raw ->
      case Jason.decode!(raw) do
        values when is_list(values) -> Enum.filter(values, &is_binary/1)
        _other -> []
      end
  end

workload_identity_addon_artifacts =
  case System.get_env("SERVICERADAR_WORKLOAD_IDENTITY_ADDON_ARTIFACTS") do
    json when is_binary(json) and json != "" ->
      case Jason.decode(json) do
        {:ok, %{} = map} -> map
        _ -> %{}
      end

    _ ->
      %{}
  end

workload_identity_addon_config = [artifacts: workload_identity_addon_artifacts]

workload_identity_addon_config =
  case System.get_env("SERVICERADAR_WORKLOAD_IDENTITY_ADDON_VERSION") do
    v when is_binary(v) and v != "" -> Keyword.put(workload_identity_addon_config, :version, v)
    _ -> workload_identity_addon_config
  end

workload_identity_addon_config =
  case System.get_env("SERVICERADAR_WORKLOAD_IDENTITY_ADDON_OCI_REF") do
    v when is_binary(v) and v != "" ->
      Keyword.put(workload_identity_addon_config, :source_oci_ref, v)

    _ ->
      workload_identity_addon_config
  end

workload_identity_addon_config =
  case System.get_env("SERVICERADAR_WORKLOAD_IDENTITY_ADDON_OCI_DIGEST") do
    v when is_binary(v) and v != "" ->
      Keyword.put(workload_identity_addon_config, :source_oci_digest, v)

    _ ->
      workload_identity_addon_config
  end

endpoint_inventory_addon_artifacts =
  case System.get_env("SERVICERADAR_ENDPOINT_INVENTORY_ADDON_ARTIFACTS") do
    json when is_binary(json) and json != "" ->
      case Jason.decode(json) do
        {:ok, %{} = map} -> map
        _ -> %{}
      end

    _ ->
      %{}
  end

endpoint_inventory_addon_config = [artifacts: endpoint_inventory_addon_artifacts]

endpoint_inventory_addon_config =
  case System.get_env("SERVICERADAR_ENDPOINT_INVENTORY_ADDON_VERSION") do
    v when is_binary(v) and v != "" -> Keyword.put(endpoint_inventory_addon_config, :version, v)
    _ -> endpoint_inventory_addon_config
  end

endpoint_inventory_addon_config =
  case System.get_env("SERVICERADAR_ENDPOINT_INVENTORY_ADDON_OCI_REF") do
    v when is_binary(v) and v != "" ->
      Keyword.put(endpoint_inventory_addon_config, :source_oci_ref, v)

    _ ->
      endpoint_inventory_addon_config
  end

endpoint_inventory_addon_config =
  case System.get_env("SERVICERADAR_ENDPOINT_INVENTORY_ADDON_OCI_DIGEST") do
    v when is_binary(v) and v != "" ->
      Keyword.put(endpoint_inventory_addon_config, :source_oci_digest, v)

    _ ->
      endpoint_inventory_addon_config
  end

geolite_dbs = base_geolite_dbs ++ city_geolite_dbs ++ ipinfo_dbs

config :geolix, databases: ServiceRadar.Observability.GeoIP.present_databases(geolite_dbs)

config :serviceradar_core,
       :endpoint_inventory_native_addon_package,
       endpoint_inventory_addon_config

config :serviceradar_core, :geolite_databases, geolite_dbs
config :serviceradar_core, :netprobe_native_addon_package, netprobe_addon_config
config :serviceradar_core, :otel_collector_native_addon_package, otel_collector_addon_config

config :serviceradar_core,
       :workload_identity_native_addon_package,
       workload_identity_addon_config

config :serviceradar_core,
  # AshCloak encryption key (required for PII encryption)
  geolite_mmdb_dir: geolite_dir,
  egress_proxy: ServiceRadar.HTTP.EgressProxy.from_env()

if is_map(remote_access_ssh_certificate_policy) and
     map_size(remote_access_ssh_certificate_policy) > 0 do
  config :serviceradar_core,
    remote_access_ssh_certificate_policy: remote_access_ssh_certificate_policy
end

config :serviceradar_core,
  remote_access_desktop_rdp_enabled: remote_access_desktop_rdp_enabled

if remote_access_ssh_ca_signer_enabled do
  signer_command =
    System.get_env(
      "SERVICERADAR_REMOTE_ACCESS_SSH_CA_SIGNER_COMMAND",
      "serviceradar-sshca-signer"
    )

  signer_ca_key_id = System.get_env("SERVICERADAR_REMOTE_ACCESS_SSH_CA_KEY_ID")

  config :serviceradar_core, RemoteAccessSSHCACommandSigner,
    command: signer_command,
    args: remote_access_ssh_ca_signer_args,
    ca_key_id: signer_ca_key_id

  config :serviceradar_core, ServiceRadar.Edge.RemoteAccessSSHCertificates,
    signer: RemoteAccessSSHCACommandSigner
end

# Tiered telemetry cold storage (OpenSpec add-tiered-telemetry-offload).
# Deployment-supplied configuration; absent => every cold-tier surface is
# inert and behavior is identical to a build without the capability.
# Deliberately OUTSIDE the prod-only block: dev/test (compose profile,
# integration suite) honor the same envs.
cold_parse_int = fn name, default ->
  case System.get_env(name) do
    nil ->
      default

    "" ->
      default

    value ->
      case Integer.parse(value) do
        {int, ""} -> int
        _ -> default
      end
  end
end

cold_secret_env = fn name ->
  case System.get_env(name <> "_FILE") do
    nil -> System.get_env(name)
    path -> path |> File.read!() |> String.trim()
  end
end

# nil when unset: a cold window must be an explicit deployment decision (D9).
cold_window = fn name ->
  case System.get_env(name) do
    nil ->
      nil

    "" ->
      nil

    value ->
      case Integer.parse(value) do
        {days, _} -> max(days, 1)
        :error -> nil
      end
  end
end

config :serviceradar_core, ServiceRadar.ColdTier,
  enabled: System.get_env("SERVICERADAR_COLD_TIER_ENABLED") in ["true", "1"],
  bucket_url: System.get_env("SERVICERADAR_COLD_TIER_BUCKET_URL"),
  s3_endpoint: System.get_env("SERVICERADAR_COLD_TIER_S3_ENDPOINT"),
  s3_endpoint_runtime: System.get_env("SERVICERADAR_COLD_TIER_S3_ENDPOINT_RUNTIME"),
  s3_region: System.get_env("SERVICERADAR_COLD_TIER_S3_REGION"),
  s3_url_style: System.get_env("SERVICERADAR_COLD_TIER_S3_URL_STYLE"),
  s3_use_ssl: System.get_env("SERVICERADAR_COLD_TIER_S3_USE_SSL", "true") in ["true", "1"],
  s3_access_key_id: cold_secret_env.("SERVICERADAR_COLD_TIER_S3_ACCESS_KEY_ID"),
  s3_secret_access_key: cold_secret_env.("SERVICERADAR_COLD_TIER_S3_SECRET_ACCESS_KEY"),
  head_host: System.get_env("SERVICERADAR_COLD_TIER_HEAD_HOST"),
  head_port: cold_parse_int.("SERVICERADAR_COLD_TIER_HEAD_PORT", 5432),
  head_database: System.get_env("SERVICERADAR_COLD_TIER_HEAD_DATABASE"),
  head_username: System.get_env("SERVICERADAR_COLD_TIER_HEAD_USERNAME"),
  head_password: cold_secret_env.("SERVICERADAR_COLD_TIER_HEAD_PASSWORD"),
  primary_host: System.get_env("SERVICERADAR_COLD_TIER_PRIMARY_HOST"),
  primary_port: cold_parse_int.("SERVICERADAR_COLD_TIER_PRIMARY_PORT", 5432),
  primary_database: System.get_env("SERVICERADAR_COLD_TIER_PRIMARY_DATABASE"),
  primary_fdw_username: System.get_env("SERVICERADAR_COLD_TIER_PRIMARY_FDW_USERNAME"),
  primary_fdw_password: cold_secret_env.("SERVICERADAR_COLD_TIER_PRIMARY_FDW_PASSWORD"),
  export_lag_hours: max(cold_parse_int.("SERVICERADAR_COLD_EXPORT_LAG_HOURS", 48), 1),
  quarantine_attempts: max(cold_parse_int.("SERVICERADAR_COLD_QUARANTINE_ATTEMPTS", 5), 1),
  run_chunk_budget: max(cold_parse_int.("SERVICERADAR_COLD_RUN_CHUNK_BUDGET", 24), 1),
  # Cold windows are what the pruner DELETES archived data by, so an absent
  # value must never materialize a default: design D9 says absent means no
  # expiry pruning at all (manifest hygiene only). nil = keep forever until a
  # deployment states a window explicitly.
  cold_windows:
    Enum.reject(
      [
        logs: cold_window.("SERVICERADAR_COLD_WINDOW_LOGS_DAYS"),
        traces: cold_window.("SERVICERADAR_COLD_WINDOW_TRACES_DAYS"),
        otel_metrics: cold_window.("SERVICERADAR_COLD_WINDOW_OTEL_METRICS_DAYS"),
        otel_metric_points: cold_window.("SERVICERADAR_COLD_WINDOW_OTEL_METRIC_POINTS_DAYS"),
        timeseries: cold_window.("SERVICERADAR_COLD_WINDOW_TIMESERIES_DAYS"),
        events: cold_window.("SERVICERADAR_COLD_WINDOW_EVENTS_DAYS"),
        flows: cold_window.("SERVICERADAR_COLD_WINDOW_FLOWS_DAYS")
      ],
      fn {_class, days} -> is_nil(days) end
    )

if config_env() == :prod do
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

  edge_crypto_secret =
    read_secret_env.("SERVICERADAR_EDGE_CRYPTO_SECRET", "SERVICERADAR_EDGE_CRYPTO_SECRET_FILE") ||
      read_secret_env.("EDGE_ONBOARDING_ENCRYPTION_KEY", "EDGE_ONBOARDING_ENCRYPTION_KEY_FILE")

  if is_binary(edge_crypto_secret) and String.trim(edge_crypto_secret) != "" do
    config :serviceradar_core, :crypto_secret, String.trim(edge_crypto_secret)
  end

  cloak_key =
    case System.get_env("CLOAK_KEY") do
      nil -> nil
      "" -> nil
      value -> value
    end ||
      case System.get_env("CLOAK_KEY_FILE") do
        nil ->
          nil

        "" ->
          nil

        path ->
          case File.read(path) do
            {:ok, contents} -> String.trim(contents)
            {:error, reason} -> raise "failed to read CLOAK_KEY_FILE #{path}: #{inspect(reason)}"
          end
      end ||
      raise """
      environment variable CLOAK_KEY (or CLOAK_KEY_FILE) is missing.
      This key is required for encrypting sensitive fields like email addresses.

      Generate a 32-byte key with:
        :crypto.strong_rand_bytes(32) |> Base.encode64()
      """

  spiffe_mode =
    case System.get_env("SPIFFE_MODE", "filesystem") do
      "workload_api" -> :workload_api
      _ -> :filesystem
    end

  spiffe_socket =
    System.get_env("SPIFFE_WORKLOAD_API_SOCKET") ||
      System.get_env("SPIFFE_ENDPOINT_SOCKET") ||
      "unix:///run/spire/sockets/agent.sock"

  spiffe_bundle_path = System.get_env("SPIFFE_TRUST_BUNDLE_PATH")

  platform_sync_component_id =
    System.get_env("SERVICERADAR_PLATFORM_SYNC_COMPONENT_ID") || "platform-sync"

  age_graph_name =
    System.get_env("SERVICERADAR_AGE_GRAPH_NAME") ||
      System.get_env("AGE_GRAPH_NAME") ||
      "platform_graph"

  topology_v2_contract_consumption_enabled =
    "SERVICERADAR_TOPOLOGY_V2_CONSUMPTION_ENABLED"
    |> System.get_env("true")
    |> String.downcase()
    |> Kernel.in(["1", "true", "yes", "on"])

  parse_bool = fn env_name, default ->
    case System.get_env(env_name) do
      nil -> default
      value -> String.downcase(value) in ["1", "true", "yes", "on"]
    end
  end

  parse_int_env = fn env_name, default ->
    case System.get_env(env_name) do
      nil ->
        default

      "" ->
        default

      value ->
        case Integer.parse(value) do
          {int, ""} -> int
          _ -> default
        end
    end
  end

  mtr_automation_enabled = parse_bool.("MTR_AUTOMATION_ENABLED", false)
  mtr_retention_days = "MTR_RETENTION_DAYS" |> parse_int_env.(30) |> max(1) |> min(395)

  observability_retention_batch_size =
    "SERVICERADAR_OBSERVABILITY_RETENTION_BATCH_SIZE" |> parse_int_env.(50_000) |> max(1)

  # OTel retention defaults (mutually consistent ordering):
  #   otel_traces (raw spans)        3 days
  #   otel_trace_summaries           3 days (summaries never outlive spans by
  #                                  more than the configured window)
  #   logs                           30 days
  #   otel_metrics (span samples)    30 days
  #   otel_metric_points (OTLP)      30 days
  #   ocsf_events                    14 days
  #   ocsf_network_activity          90 days
  trace_summary_retention_days =
    "SERVICERADAR_TRACE_SUMMARY_RETENTION_DAYS" |> parse_int_env.(3) |> max(1)

  otel_traces_retention_days =
    "SERVICERADAR_OTEL_TRACES_RETENTION_DAYS" |> parse_int_env.(3) |> max(1)

  logs_retention_days = "SERVICERADAR_LOGS_RETENTION_DAYS" |> parse_int_env.(30) |> max(1)

  otel_metrics_retention_days =
    "SERVICERADAR_OTEL_METRICS_RETENTION_DAYS" |> parse_int_env.(30) |> max(1)

  otel_metric_points_retention_days =
    "SERVICERADAR_OTEL_METRIC_POINTS_RETENTION_DAYS" |> parse_int_env.(30) |> max(1)

  ocsf_events_retention_days =
    "SERVICERADAR_OCSF_EVENTS_RETENTION_DAYS" |> parse_int_env.(14) |> max(1)

  ocsf_network_activity_retention_days =
    "SERVICERADAR_OCSF_NETWORK_ACTIVITY_RETENTION_DAYS" |> parse_int_env.(90) |> max(1)

  timeseries_metrics_retention_days =
    "SERVICERADAR_TIMESERIES_METRICS_RETENTION_DAYS" |> parse_int_env.(7) |> max(1)

  flow_attribution_retention_minutes =
    "SERVICERADAR_FLOW_ATTRIBUTION_RETENTION_MINUTES" |> parse_int_env.(60) |> max(15)

  # Root-span-ratio ingest-health signal (RootSpanRatioWorker): warn when
  # more than `threshold` of the spans ingested in the last 15 minutes are
  # root spans, once at least `min_spans` spans are present.
  root_span_ratio_threshold =
    case Float.parse(System.get_env("SERVICERADAR_ROOT_SPAN_RATIO_THRESHOLD") || "") do
      {value, ""} when value > 0.0 and value <= 1.0 -> value
      _ -> 0.85
    end

  root_span_ratio_min_spans =
    "SERVICERADAR_ROOT_SPAN_RATIO_MIN_SPANS" |> parse_int_env.(1000) |> max(1)

  # Chunk intervals must be small enough that retention can actually drop
  # chunks within one policy period (1h chunks for 3-day span retention,
  # 6h chunks for 30-day logs retention).
  otel_traces_chunk_interval_hours =
    "SERVICERADAR_OTEL_TRACES_CHUNK_INTERVAL_HOURS" |> parse_int_env.(1) |> max(1)

  logs_chunk_interval_hours =
    "SERVICERADAR_LOGS_CHUNK_INTERVAL_HOURS" |> parse_int_env.(6) |> max(1)

  otel_metrics_chunk_interval_hours =
    "SERVICERADAR_OTEL_METRICS_CHUNK_INTERVAL_HOURS" |> parse_int_env.(24) |> max(1)

  otel_metric_points_chunk_interval_hours =
    "SERVICERADAR_OTEL_METRIC_POINTS_CHUNK_INTERVAL_HOURS" |> parse_int_env.(6) |> max(1)

  ocsf_events_chunk_interval_hours =
    "SERVICERADAR_OCSF_EVENTS_CHUNK_INTERVAL_HOURS" |> parse_int_env.(6) |> max(1)

  ocsf_network_activity_chunk_interval_hours =
    "SERVICERADAR_OCSF_NETWORK_ACTIVITY_CHUNK_INTERVAL_HOURS" |> parse_int_env.(24) |> max(1)

  netflow_security_refresh_reschedule_seconds =
    "NETFLOW_SECURITY_REFRESH_INTERVAL_SECONDS"
    |> System.get_env()
    |> case do
      nil -> 86_400
      "" -> 86_400
      _ -> max(parse_int_env.("NETFLOW_SECURITY_REFRESH_INTERVAL_SECONDS", 86_400), 86_400)
    end

  netflow_security_refresh_cache_ttl_seconds =
    "NETFLOW_SECURITY_REFRESH_CACHE_TTL_SECONDS"
    |> System.get_env()
    |> case do
      nil ->
        netflow_security_refresh_reschedule_seconds

      "" ->
        netflow_security_refresh_reschedule_seconds

      _ ->
        parse_int_env.(
          "NETFLOW_SECURITY_REFRESH_CACHE_TTL_SECONDS",
          netflow_security_refresh_reschedule_seconds
        )
    end

  netflow_security_threat_candidate_limit =
    parse_int_env.("NETFLOW_SECURITY_THREAT_CANDIDATE_LIMIT", 10_000)

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

  parse_int = fn value ->
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> nil
    end
  end

  pool_size = parse_int.(System.get_env("POOL_SIZE") || "10") || 10
  search_path = System.get_env("CNPG_SEARCH_PATH", "platform, public, ag_catalog")

  database_timeout =
    "DATABASE_TIMEOUT_MS"
    |> System.get_env()
    |> case do
      nil -> nil
      "" -> nil
      value -> parse_int.(value)
    end

  database_pool_timeout =
    "DATABASE_POOL_TIMEOUT_MS"
    |> System.get_env()
    |> case do
      nil -> nil
      "" -> nil
      value -> parse_int.(value)
    end

  database_prepare =
    case System.get_env("DATABASE_PREPARE", "") do
      "unnamed" -> :unnamed
      "named" -> :named
      _ -> nil
    end

  repo_opts = [
    url: database_url,
    ssl: ssl_opts,
    socket_options: maybe_ipv6,
    pool_size: pool_size,
    parameters: [search_path: search_path],
    types: ServiceRadar.PostgresTypes
  ]

  queue_target =
    "DATABASE_QUEUE_TARGET_MS"
    |> System.get_env()
    |> case do
      nil -> nil
      "" -> nil
      value -> parse_int.(value)
    end

  queue_interval =
    "DATABASE_QUEUE_INTERVAL_MS"
    |> System.get_env()
    |> case do
      nil -> nil
      "" -> nil
      value -> parse_int.(value)
    end

  repo_opts =
    repo_opts
    |> then(fn opts ->
      if queue_target, do: Keyword.put(opts, :queue_target, queue_target), else: opts
    end)
    |> then(fn opts ->
      if queue_interval, do: Keyword.put(opts, :queue_interval, queue_interval), else: opts
    end)
    |> then(fn opts ->
      if database_timeout, do: Keyword.put(opts, :timeout, database_timeout), else: opts
    end)
    |> then(fn opts ->
      if database_pool_timeout,
        do: Keyword.put(opts, :pool_timeout, database_pool_timeout),
        else: opts
    end)
    |> then(fn opts ->
      if database_prepare, do: Keyword.put(opts, :prepare, database_prepare), else: opts
    end)

  control_repo_pool_size =
    parse_int.(System.get_env("CONTROL_REPO_POOL_SIZE") || "5") || 5

  control_repo_queue_target =
    "CONTROL_DATABASE_QUEUE_TARGET_MS"
    |> System.get_env()
    |> case do
      nil -> queue_target
      "" -> nil
      value -> parse_int.(value)
    end

  control_repo_queue_interval =
    "CONTROL_DATABASE_QUEUE_INTERVAL_MS"
    |> System.get_env()
    |> case do
      nil -> queue_interval
      "" -> nil
      value -> parse_int.(value)
    end

  control_repo_timeout =
    "CONTROL_DATABASE_TIMEOUT_MS"
    |> System.get_env()
    |> case do
      nil -> database_timeout
      "" -> nil
      value -> parse_int.(value)
    end

  control_repo_pool_timeout =
    "CONTROL_DATABASE_POOL_TIMEOUT_MS"
    |> System.get_env()
    |> case do
      nil -> database_pool_timeout
      "" -> nil
      value -> parse_int.(value)
    end

  # Ecto logs every statement, and repo_opts above sets no :log key, so it defaults to logging
  # each one. In the integration suite that produced ~40MB of begin/commit/advisory-lock/SELECT
  # noise in a single run -- 4842 "begin" lines alone -- burying the four real failures at line
  # 239878 of a 239911-line log.
  #
  # This belongs here rather than in config/test.exs for two reasons. Runtime config is applied
  # last and replaces the ServiceRadar.Repo config wholesale, so a :log key set in test.exs is
  # discarded. And placing it before control_repo_opts is derived below means ControlRepo
  # inherits it too, rather than needing a second copy.
  #
  # Ecto's :log is the level queries are logged AT, not a threshold, so `false` is the only way
  # to silence them. Failing queries still surface through the exceptions they raise.
  repo_opts =
    if config_env() == :test do
      Keyword.put(repo_opts, :log, false)
    else
      repo_opts
    end

  control_repo_opts =
    repo_opts
    |> Keyword.put(:pool_size, control_repo_pool_size)
    |> then(fn opts ->
      if control_repo_queue_target,
        do: Keyword.put(opts, :queue_target, control_repo_queue_target),
        else: opts
    end)
    |> then(fn opts ->
      if control_repo_queue_interval,
        do: Keyword.put(opts, :queue_interval, control_repo_queue_interval),
        else: opts
    end)
    |> then(fn opts ->
      if control_repo_timeout, do: Keyword.put(opts, :timeout, control_repo_timeout), else: opts
    end)
    |> then(fn opts ->
      if control_repo_pool_timeout,
        do: Keyword.put(opts, :pool_timeout, control_repo_pool_timeout),
        else: opts
    end)

  sweep_srql_page_limit =
    "SWEEP_SRQL_PAGE_LIMIT"
    |> System.get_env()
    |> case do
      nil -> nil
      "" -> nil
      value -> parse_int.(value)
    end

  sync_ingestor_batch_concurrency =
    "SYNC_INGESTOR_BATCH_CONCURRENCY"
    |> System.get_env()
    |> case do
      nil -> nil
      "" -> nil
      value -> parse_int.(value)
    end

  sync_ingestor_coalesce_ms =
    "SYNC_INGESTOR_COALESCE_MS"
    |> System.get_env()
    |> case do
      nil -> nil
      "" -> nil
      value -> parse_int.(value)
    end

  sync_ingestor_max_inflight =
    "SYNC_INGESTOR_MAX_INFLIGHT"
    |> System.get_env()
    |> case do
      nil -> nil
      "" -> nil
      value -> parse_int.(value)
    end

  sync_ingestor_queue_max_chunks =
    "SYNC_INGESTOR_QUEUE_MAX_CHUNKS"
    |> System.get_env()
    |> case do
      nil -> nil
      "" -> nil
      value -> parse_int.(value)
    end

  plugin_storage_defaults = Application.get_env(:serviceradar_core, :plugin_storage, [])

  plugin_storage_overrides =
    []
    |> then(fn acc ->
      case System.get_env("PLUGIN_STORAGE_PUBLIC_URL") do
        nil -> acc
        "" -> acc
        value -> Keyword.put(acc, :public_url, value)
      end
    end)
    |> then(fn acc ->
      case read_secret_env.("PLUGIN_STORAGE_SIGNING_SECRET", "PLUGIN_STORAGE_SIGNING_SECRET_FILE") do
        nil -> acc
        "" -> acc
        value -> Keyword.put(acc, :signing_secret, value)
      end
    end)
    |> then(fn acc ->
      case System.get_env("PLUGIN_STORAGE_DOWNLOAD_TTL_SECONDS") do
        nil ->
          acc

        "" ->
          acc

        value ->
          case Integer.parse(value) do
            {parsed, ""} -> Keyword.put(acc, :download_ttl_seconds, parsed)
            _ -> acc
          end
      end
    end)

  # Cluster configuration
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
    get_in(hosted_cluster_contract, ["strategy"]) ||
      "CLUSTER_STRATEGY"
      |> System.get_env("epmd")
      |> String.downcase()

  cluster_enabled =
    case get_in(hosted_cluster_contract, ["enabled"]) do
      value when is_boolean(value) -> value
      _ -> System.get_env("CLUSTER_ENABLED", "true") in ~w(true 1 yes)
    end

  topologies =
    if cluster_enabled do
      case cluster_strategy do
        "kubernetes" ->
          namespace = System.get_env("NAMESPACE", "serviceradar")
          kubernetes_selector = System.get_env("KUBERNETES_SELECTOR", "app=serviceradar-core")

          kubernetes_node_basename =
            System.get_env("KUBERNETES_NODE_BASENAME", "serviceradar_core")

          web_service =
            System.get_env("CLUSTER_WEB_SERVICE", "serviceradar-web-ng-headless")

          web_node_basename =
            System.get_env("CLUSTER_WEB_NODE_BASENAME", "serviceradar_web_ng")

          gateway_service =
            System.get_env("CLUSTER_GATEWAY_SERVICE", "serviceradar-agent-gateway-headless")

          gateway_node_basename =
            System.get_env("CLUSTER_GATEWAY_NODE_BASENAME", "serviceradar_agent_gateway")

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
            ],
            serviceradar_web: [
              strategy: DNS,
              config: [
                service: web_service,
                application_name: web_node_basename,
                namespace: namespace,
                polling_interval: 5_000
              ]
            ],
            serviceradar_gateway: [
              strategy: DNS,
              config: [
                service: gateway_service,
                application_name: gateway_node_basename,
                namespace: namespace,
                polling_interval: 5_000
              ]
            ]
          ]

        "dns" ->
          dns_query =
            get_in(hosted_cluster_contract, ["core", "dns_query"]) ||
              System.get_env("CLUSTER_DNS_QUERY", "")

          node_basename =
            get_in(hosted_cluster_contract, ["core", "node_basename"]) ||
              System.get_env("CLUSTER_NODE_BASENAME", "serviceradar_core")

          web_dns_query =
            get_in(hosted_cluster_contract, ["core", "web_dns_query"]) ||
              System.get_env("CLUSTER_WEB_DNS_QUERY", "")

          web_node_basename =
            get_in(hosted_cluster_contract, ["core", "web_node_basename"]) ||
              System.get_env("CLUSTER_WEB_NODE_BASENAME", "serviceradar_web_ng")

          gateway_dns_query =
            get_in(hosted_cluster_contract, ["core", "gateway_dns_query"]) ||
              System.get_env("CLUSTER_GATEWAY_DNS_QUERY", "")

          gateway_node_basename =
            get_in(hosted_cluster_contract, ["core", "gateway_node_basename"]) ||
              System.get_env("CLUSTER_GATEWAY_NODE_BASENAME", "serviceradar_agent_gateway")

          maybe_add_dns_topology = fn current_topologies, name, query, basename ->
            if query in [nil, ""] do
              current_topologies
            else
              current_topologies ++
                [
                  {name,
                   [
                     strategy: DNSPoll,
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
          |> maybe_add_dns_topology.(:serviceradar_web, web_dns_query, web_node_basename)
          |> maybe_add_dns_topology.(
            :serviceradar_gateway,
            gateway_dns_query,
            gateway_node_basename
          )

        "epmd" ->
          hosts_str = System.get_env("CLUSTER_HOSTS", "")

          # libcluster's Epmd strategy requires node-NAME atoms, and deployment-specific
          # hostnames have no pre-known whitelist, so `String.to_existing_atom` is not an
          # option here. CLUSTER_HOSTS is trusted operator config, but bound the atom
          # creation regardless: drop blanks/dupes and cap the count so a malformed env
          # var can never grow the atom table without bound.
          hosts =
            hosts_str
            |> String.split(",", trim: true)
            |> Enum.map(&String.trim/1)
            |> Enum.reject(&(&1 == ""))
            |> Enum.uniq()
            |> Enum.take(256)
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

  otx_env = fn env_name ->
    case System.get_env(env_name) do
      nil -> nil
      "" -> nil
      value -> value
    end
  end

  otx_api_key =
    read_secret_env.(
      "SERVICERADAR_OTX_API_KEY",
      "SERVICERADAR_OTX_API_KEY_FILE"
    )

  otx_provider_config =
    %{
      "api_key" => otx_api_key,
      "base_url" => otx_env.("SERVICERADAR_OTX_BASE_URL"),
      "modified_since" => otx_env.("SERVICERADAR_OTX_MODIFIED_SINCE"),
      "limit" => parse_int_env.("SERVICERADAR_OTX_PAGE_SIZE", nil),
      "page" => parse_int_env.("SERVICERADAR_OTX_PAGE", nil),
      "timeout_ms" => parse_int_env.("SERVICERADAR_OTX_TIMEOUT_MS", nil),
      "max_retries" => parse_int_env.("SERVICERADAR_OTX_MAX_RETRIES", nil),
      "backoff_ms" => parse_int_env.("SERVICERADAR_OTX_BACKOFF_MS", nil)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()

  config :serviceradar_core, ServiceRadar.ControlRepo, control_repo_opts

  config :serviceradar_core, ServiceRadar.Observability.NetflowSecurityRefreshWorker,
    reschedule_seconds: netflow_security_refresh_reschedule_seconds,
    cache_ttl_seconds: netflow_security_refresh_cache_ttl_seconds,
    threat_candidate_limit: netflow_security_threat_candidate_limit

  if otx_provider_config != %{} do
    config :serviceradar_core, ServiceRadar.Observability.ThreatIntelOTXSyncWorker,
      provider_config: otx_provider_config,
      plugin_id: "alienvault-otx-core",
      partition: System.get_env("SERVICERADAR_OTX_PARTITION", "default")
  end

  otx_raw_storage =
    case System.get_env("SERVICERADAR_OTX_RAW_STORAGE", "file") do
      "memory" -> :memory
      _ -> :file
    end

  config :serviceradar_core, ServiceRadar.Observability.ThreatIntelRawPayloadStore,
    jetstream_bucket: System.get_env("SERVICERADAR_OTX_RAW_BUCKET", "serviceradar_threat_intel"),
    jetstream_ttl_seconds: parse_int_env.("SERVICERADAR_OTX_RAW_TTL_SECONDS", 0),
    jetstream_max_bucket_size: parse_int_env.("SERVICERADAR_OTX_RAW_MAX_BUCKET_BYTES", nil),
    jetstream_max_chunk_size: parse_int_env.("SERVICERADAR_OTX_RAW_MAX_CHUNK_BYTES", nil),
    jetstream_replicas: parse_int_env.("SERVICERADAR_OTX_RAW_REPLICAS", 1),
    jetstream_storage: otx_raw_storage

  config :serviceradar_core, ServiceRadar.Repo, repo_opts
  config :serviceradar_core, :age_graph_name, age_graph_name
  config :serviceradar_core, :platform_sync_component_id, platform_sync_component_id

  config :serviceradar_core, :spiffe,
    mode: spiffe_mode,
    trust_domain: System.get_env("SPIFFE_TRUST_DOMAIN", "serviceradar.local"),
    cert_dir: System.get_env("SPIFFE_CERT_DIR", "/etc/serviceradar/certs"),
    workload_api_socket: spiffe_socket,
    trust_bundle_path: spiffe_bundle_path

  config :serviceradar_core,
    control_repo_enabled: System.get_env("CONTROL_REPO_ENABLED", "true") in ~w(true 1 yes)

  if topologies != [] do
    config :libcluster, topologies: topologies
  end

  # Ansible integration retention + worker cadences. RetentionWorker
  # treats `0` as "disabled" for run_detail_days; nil / unset for
  # run_summary_days means "keep forever".
  ansible_retention_run_detail_days =
    "ANSIBLE_RETENTION_RUN_DETAIL_DAYS" |> parse_int_env.(90) |> max(0)

  ansible_retention_run_summary_days =
    case parse_int_env.("ANSIBLE_RETENTION_RUN_SUMMARY_DAYS", 0) do
      n when is_integer(n) and n > 0 -> n
      _ -> nil
    end

  config :serviceradar_core, DataRetentionWorker,
    batch_size: observability_retention_batch_size,
    trace_summary_retention_days: trace_summary_retention_days,
    otel_traces_retention_days: otel_traces_retention_days,
    logs_retention_days: logs_retention_days,
    otel_metrics_retention_days: otel_metrics_retention_days,
    otel_metric_points_retention_days: otel_metric_points_retention_days,
    ocsf_events_retention_days: ocsf_events_retention_days,
    ocsf_network_activity_retention_days: ocsf_network_activity_retention_days,
    timeseries_metrics_retention_days: timeseries_metrics_retention_days,
    otel_traces_chunk_interval_hours: otel_traces_chunk_interval_hours,
    logs_chunk_interval_hours: logs_chunk_interval_hours,
    otel_metrics_chunk_interval_hours: otel_metrics_chunk_interval_hours,
    otel_metric_points_chunk_interval_hours: otel_metric_points_chunk_interval_hours,
    ocsf_events_chunk_interval_hours: ocsf_events_chunk_interval_hours,
    ocsf_network_activity_chunk_interval_hours: ocsf_network_activity_chunk_interval_hours,
    sweep_host_result_retention_days:
      "SERVICERADAR_SWEEP_HOST_RESULT_RETENTION_DAYS" |> parse_int_env.(7) |> max(1),
    sweep_execution_retention_days:
      "SERVICERADAR_SWEEP_EXECUTION_RETENTION_DAYS" |> parse_int_env.(30) |> max(1),
    trivy_retention_days: "SERVICERADAR_TRIVY_RETENTION_DAYS" |> parse_int_env.(30) |> max(1),
    endpoint_inventory_retention_days:
      "SERVICERADAR_ENDPOINT_INVENTORY_RETENTION_DAYS" |> parse_int_env.(30) |> max(1),
    dataset_snapshot_retention_days:
      "SERVICERADAR_DATASET_SNAPSHOT_RETENTION_DAYS" |> parse_int_env.(2) |> max(1),
    dataset_snapshot_keep_last:
      "SERVICERADAR_DATASET_SNAPSHOT_KEEP_LAST" |> parse_int_env.(1) |> max(0),
    topology_link_retention_days:
      "SERVICERADAR_TOPOLOGY_LINK_RETENTION_DAYS" |> parse_int_env.(30) |> max(1)

  config :serviceradar_core, RefreshTraceSummariesWorker,
    retention_days: trace_summary_retention_days,
    cleanup_batch_size: "TRACE_SUMMARIES_CLEANUP_BATCH_SIZE" |> parse_int_env.(5_000) |> max(1),
    cleanup_time_budget_ms:
      "TRACE_SUMMARIES_CLEANUP_TIME_BUDGET_MS" |> parse_int_env.(10_000) |> max(1),
    probe_timeout_ms: "TRACE_SUMMARIES_PROBE_TIMEOUT_MS" |> parse_int_env.(30_000) |> max(1),
    upsert_timeout_ms: "TRACE_SUMMARIES_UPSERT_TIMEOUT_MS" |> parse_int_env.(120_000) |> max(1),
    watermark_timeout_ms:
      "TRACE_SUMMARIES_WATERMARK_TIMEOUT_MS" |> parse_int_env.(30_000) |> max(1),
    cleanup_timeout_ms: "TRACE_SUMMARIES_CLEANUP_TIMEOUT_MS" |> parse_int_env.(60_000) |> max(1),
    remaining_estimate_timeout_ms:
      "TRACE_SUMMARIES_REMAINING_ESTIMATE_TIMEOUT_MS" |> parse_int_env.(30_000) |> max(1)

  config :serviceradar_core, RootSpanRatioWorker,
    threshold: root_span_ratio_threshold,
    min_spans: root_span_ratio_min_spans

  # Agent-command history retention. The cleanup worker prunes terminal-state
  # rows (completed/failed/expired/canceled/offline) older than the window using
  # a batched, set-based DELETE. Default window is 2 days (short-term audit /
  # troubleshooting table); the sweep self-reschedules hourly by default.
  config :serviceradar_core, ServiceRadar.Edge.AgentCommandCleanupWorker,
    retention_days: "AGENT_COMMAND_RETENTION_DAYS" |> parse_int_env.(2) |> max(1),
    reschedule_seconds:
      "AGENT_COMMAND_CLEANUP_INTERVAL_SECONDS" |> parse_int_env.(3_600) |> max(60)

  config :serviceradar_core, ServiceRadar.FlowAttribution,
    retention_minutes: flow_attribution_retention_minutes

  # Heartbeat for the canonical-topology rebuild change-detection skip: when the
  # observed graph is structurally unchanged, still rebuild at most once per this
  # window so property-only edge changes are bounded to one heartbeat of staleness.
  # Lower it in prod (faster discovery) to tighten that bound; the default kills the
  # per-report churn for a mostly-static demo topology.
  config :serviceradar_core, ServiceRadar.NetworkDiscovery.TopologyGraph,
    canonical_rebuild_heartbeat_ms:
      parse_int_env.("SERVICERADAR_TOPOLOGY_CANONICAL_REBUILD_HEARTBEAT_MS", 3_600_000),
    # Starvation guard (fj #4378): a rebuild whose canonical edge count after
    # the upsert is at or below this floor while mapper evidence exists is
    # treated as starved (stale prune skipped, starvation signal raised).
    # 0 = only an empty canonical graph triggers via the count term; the
    # evidence-freshness term catches the first fatal run regardless.
    canonical_rebuild_min_upsert_floor:
      "SERVICERADAR_TOPOLOGY_CANONICAL_REBUILD_MIN_UPSERT_FLOOR"
      |> parse_int_env.(0)
      |> max(0),
    # Mass-deletion guardrail: refuse a single stale-prune pass that would
    # delete more than this percentage of the canonical edges (default 50%).
    canonical_prune_max_fraction:
      "SERVICERADAR_TOPOLOGY_CANONICAL_PRUNE_MAX_PERCENT"
      |> parse_int_env.(50)
      |> max(1)
      |> min(100)
      |> Kernel./(100),
    # Operator override for the guardrail: set to force a legitimate large
    # prune (e.g. after a deliberate topology cutover), then unset.
    canonical_prune_guard_override:
      parse_bool.("SERVICERADAR_TOPOLOGY_CANONICAL_PRUNE_GUARD_OVERRIDE", false)

  # Change-detection skip-guard for workload-identity snapshot upserts (fj #33).
  # persist_snapshot/1 runs once per agent status; on a stable cluster the
  # container->identity content rarely changes, so the guard fingerprints that
  # content and skips the redundant workload_identity_current upsert when it is
  # unchanged, refreshing observed_at at most once per heartbeat. Set
  # SERVICERADAR_WORKLOAD_IDENTITY_SKIP_GUARD=0 to always write (disable). The
  # table is not retention-pruned, so the heartbeat only bounds observed_at
  # staleness (default 30 min).
  config :serviceradar_core, ServiceRadar.WorkloadIdentity,
    skip_guard_enabled: System.get_env("SERVICERADAR_WORKLOAD_IDENTITY_SKIP_GUARD", "1") != "0",
    skip_guard_heartbeat_ms:
      parse_int_env.("SERVICERADAR_WORKLOAD_IDENTITY_SKIP_GUARD_HEARTBEAT_MS", 1_800_000)

  config :serviceradar_core,
    ansible_retention_run_detail_days: ansible_retention_run_detail_days,
    ansible_retention_run_summary_days: ansible_retention_run_summary_days,
    ansible_retention_interval_seconds:
      "ANSIBLE_RETENTION_INTERVAL_SECONDS" |> parse_int_env.(86_400) |> max(3_600),
    awx_controller_health_interval_seconds:
      "AWX_CONTROLLER_HEALTH_INTERVAL_SECONDS" |> parse_int_env.(30) |> max(5),
    awx_run_watchdog_interval_seconds:
      "AWX_RUN_WATCHDOG_INTERVAL_SECONDS" |> parse_int_env.(60) |> max(30),
    awx_schedule_evaluator_interval_seconds:
      "AWX_SCHEDULE_EVALUATOR_INTERVAL_SECONDS" |> parse_int_env.(60) |> max(30),
    ansible_catalog_base_dir:
      System.get_env("ANSIBLE_CATALOG_BASE_DIR") ||
        Path.join(System.tmp_dir!(), "serviceradar_ansible_catalog")

  config :serviceradar_core,
    cluster_enabled: cluster_enabled

  config :serviceradar_core,
    device_enrichment_rules_dir:
      System.get_env(
        "DEVICE_ENRICHMENT_RULES_DIR",
        "/var/lib/serviceradar/rules/device-enrichment"
      )

  config :serviceradar_core,
    env: :prod,
    cloak_key: cloak_key

  config :serviceradar_core,
    mapper_topology_edge_stale_minutes:
      parse_int_env.("SERVICERADAR_MAPPER_TOPOLOGY_EDGE_STALE_MINUTES", 180)

  config :serviceradar_core,
    mtr_automation_enabled: mtr_automation_enabled,
    mtr_retention_days: mtr_retention_days,
    mtr_automation_baseline_enabled:
      parse_bool.("MTR_AUTOMATION_BASELINE_ENABLED", mtr_automation_enabled),
    mtr_automation_trigger_enabled:
      parse_bool.("MTR_AUTOMATION_TRIGGER_ENABLED", mtr_automation_enabled),
    mtr_automation_consensus_enabled:
      parse_bool.("MTR_AUTOMATION_CONSENSUS_ENABLED", mtr_automation_enabled)

  # Prefix-tag flow enrichment (LPM trie). Defaults match config.exs; operators
  # enable enrichment only after migration 20260718010000 is applied everywhere.
  config :serviceradar_core,
    prefix_tag_enrichment_enabled:
      parse_bool.("SERVICERADAR_PREFIX_TAG_ENRICHMENT_ENABLED", false),
    prefix_tag_provider_trie_enabled:
      parse_bool.("SERVICERADAR_PREFIX_TAG_PROVIDER_TRIE_ENABLED", true),
    threat_intel_engine_match_enabled:
      parse_bool.("SERVICERADAR_THREAT_INTEL_ENGINE_MATCH_ENABLED", true),
    geo_tag_derivation_enabled: parse_bool.("SERVICERADAR_GEO_TAG_DERIVATION_ENABLED", false),
    prefix_tags_loader_enabled: parse_bool.("SERVICERADAR_PREFIX_TAGS_LOADER_ENABLED", true)

  config :serviceradar_core,
    run_startup_migrations:
      System.get_env("SERVICERADAR_CORE_RUN_MIGRATIONS", "false") in ~w(true 1 yes)

  # Status handler for agent-gateway push results (core-elx only)
  config :serviceradar_core,
    status_handler_enabled: System.get_env("STATUS_HANDLER_ENABLED", "true") in ~w(true 1 yes)

  config :serviceradar_core,
    sweep_srql_page_limit: sweep_srql_page_limit || 500

  config :serviceradar_core,
    sync_ingestor_async: System.get_env("SYNC_INGESTOR_ASYNC", "true") in ~w(true 1 yes)

  config :serviceradar_core,
    sync_ingestor_batch_concurrency: sync_ingestor_batch_concurrency || 2

  config :serviceradar_core,
    sync_ingestor_coalesce_ms: sync_ingestor_coalesce_ms || 250

  config :serviceradar_core,
    sync_ingestor_max_inflight: sync_ingestor_max_inflight || 2

  config :serviceradar_core,
    sync_ingestor_queue_max_chunks: sync_ingestor_queue_max_chunks || 10

  # Endpoint attachment identity promotion (fix-topology-evidence-pipeline-
  # resilience, task 3.1/3.3): when enabled, FDB/UniFi-client topology
  # neighbors mint provisional MAC-keyed `sr:` devices instead of being
  # suppressed, so switch<->host attachment edges can render. Default off for
  # one release; enable on demo first and watch device_identifiers growth and
  # inventory counts.
  config :serviceradar_core,
    topology_endpoint_identity_promotion_enabled:
      parse_bool.("SERVICERADAR_TOPOLOGY_ENDPOINT_IDENTITY_PROMOTION", false)

  config :serviceradar_core,
    topology_v2_contract_consumption_enabled: topology_v2_contract_consumption_enabled

  if plugin_storage_overrides != [] do
    config :serviceradar_core,
           :plugin_storage,
           Keyword.merge(plugin_storage_defaults, plugin_storage_overrides)
  end

  # Core NATS connection configuration
  nats_enabled = System.get_env("NATS_ENABLED", "false") in ~w(true 1 yes)
  nats_url = System.get_env("NATS_URL", "nats://localhost:4222")
  nats_uri = URI.parse(nats_url)
  nats_tls_enabled = System.get_env("NATS_TLS", "false") in ~w(true 1 yes)
  nats_server_name = System.get_env("NATS_SERVER_NAME", "nats.serviceradar")
  cert_dir = System.get_env("SPIFFE_CERT_DIR", "/etc/serviceradar/certs")
  nats_creds_file = System.get_env("NATS_CREDS_FILE")

  oban_notifier =
    case "OBAN_NOTIFIER" |> System.get_env("postgres") |> String.downcase() do
      value when value in ["pg", "process_group", "process-groups"] -> Oban.Notifiers.PG
      _ -> Oban.Notifiers.Postgres
    end

  # Oban configuration
  object_store_retention_enabled =
    System.get_env("OBJECT_STORE_RETENTION_ENABLED", "true") in ~w(true 1 yes)

  object_store_retention_dry_run =
    System.get_env("OBJECT_STORE_RETENTION_DRY_RUN", "false") in ~w(true 1 yes)

  object_store_retention_cron =
    System.get_env("OBJECT_STORE_RETENTION_CRON", "0 3 * * *")

  object_store_retention_crontab =
    if object_store_retention_enabled do
      [
        {object_store_retention_cron, ServiceRadar.ObjectStore.RetentionWorker,
         args: %{"enabled" => true}, queue: :maintenance}
      ]
    else
      []
    end

  capacity_forecasting_enabled =
    "SERVICERADAR_CAPACITY_FORECASTING_ENABLED"
    |> System.get_env("true")
    |> String.downcase()
    |> Kernel.in(["1", "true", "yes", "on"])

  capacity_forecasting_cron =
    System.get_env("SERVICERADAR_CAPACITY_FORECASTING_CRON", "41 * * * *")

  capacity_forecasting_horizon_seconds =
    String.to_integer(
      System.get_env("SERVICERADAR_CAPACITY_FORECASTING_HORIZON_SECONDS") || "7776000"
    )

  capacity_forecasting_warning_horizon_seconds =
    String.to_integer(
      System.get_env("SERVICERADAR_CAPACITY_FORECASTING_WARNING_HORIZON_SECONDS") ||
        Integer.to_string(capacity_forecasting_horizon_seconds)
    )

  capacity_forecasting_emit_verdicts =
    "SERVICERADAR_CAPACITY_FORECASTING_EMIT_VERDICTS"
    |> System.get_env("true")
    |> String.downcase()
    |> Kernel.in(["1", "true", "yes", "on"])

  capacity_forecasting_crontab =
    if capacity_forecasting_enabled do
      [
        {capacity_forecasting_cron, CapacityForecastingWorker,
         args: %{"trigger" => "cron"}, queue: :maintenance}
      ]
    else
      []
    end

  oban_lifeline_rescue_after_ms =
    "OBAN_LIFELINE_RESCUE_AFTER_MS"
    |> System.get_env(Integer.to_string(to_timeout(minute: 240)))
    |> String.to_integer()

  config :serviceradar_core, CapacityForecastingWorker,
    enabled: capacity_forecasting_enabled,
    horizon_seconds: capacity_forecasting_horizon_seconds,
    warning_horizon_seconds: capacity_forecasting_warning_horizon_seconds,
    emit_verdicts?: capacity_forecasting_emit_verdicts,
    min_points:
      String.to_integer(System.get_env("SERVICERADAR_CAPACITY_FORECASTING_MIN_POINTS") || "24"),
    seasonal_period:
      String.to_integer(
        System.get_env("SERVICERADAR_CAPACITY_FORECASTING_SEASONAL_PERIOD") || "24"
      ),
    # Comma-separated source names; the worker validates against the known
    # source list at run time. A non-empty Settings value overrides this.
    default_source_opt_ins: ProductionSchedule.capacity_source_opt_ins()

  # Notification continuation, silence expiry, and delivery retention. Built by
  # ServiceRadar.Notifications.DispatchSchedule so this tree and
  # serviceradar_core_elx's runtime.exs cannot drift; unset env leaves each
  # worker's own defaults authoritative.
  config :serviceradar_core,
         NotificationContinuationWorker,
         DispatchSchedule.continuation_worker_config()

  # The platform-resident serviceradar-agent that runs :control_plane wasm
  # notification plugins (design D3, tasks 3.3.1). There is deliberately no
  # default: guessing an agent id would dispatch notifications to whichever
  # agent happened to match, so an unset value fails the delivery with
  # `platform_agent_unconfigured` instead.
  config :serviceradar_core,
         NotificationPluginTarget,
         platform_agent_uid: System.get_env("SERVICERADAR_NOTIFICATION_PLATFORM_AGENT_ID"),
         platform_agent_partition_id:
           System.get_env("SERVICERADAR_NOTIFICATION_PLATFORM_AGENT_PARTITION")

  config :serviceradar_core,
         NotificationReceiptWorker,
         DispatchSchedule.receipt_worker_config()

  config :serviceradar_core,
         NotificationRetentionWorker,
         DispatchSchedule.delivery_retention_worker_config()

  config :serviceradar_core,
         NotificationSilenceExpiryWorker,
         DispatchSchedule.silence_expiry_worker_config()

  config :serviceradar_core, Oban,
    engine: Oban.Engines.Basic,
    repo: ServiceRadar.Repo,
    prefix: System.get_env("OBAN_SCHEMA", "platform"),
    notifier: oban_notifier,
    queues: [
      default: String.to_integer(System.get_env("OBAN_QUEUE_DEFAULT") || "10"),
      maintenance: String.to_integer(System.get_env("OBAN_QUEUE_MAINTENANCE") || "2"),
      monitoring: String.to_integer(System.get_env("OBAN_QUEUE_MONITORING") || "5"),
      alerts: String.to_integer(System.get_env("OBAN_QUEUE_ALERTS") || "5"),
      service_checks: String.to_integer(System.get_env("OBAN_QUEUE_SERVICE_CHECKS") || "10"),
      notifications: String.to_integer(System.get_env("OBAN_QUEUE_NOTIFICATIONS") || "5"),
      onboarding: String.to_integer(System.get_env("OBAN_QUEUE_ONBOARDING") || "3"),
      events: String.to_integer(System.get_env("OBAN_QUEUE_EVENTS") || "10"),
      sweeps: String.to_integer(System.get_env("OBAN_QUEUE_SWEEPS") || "20"),
      edge: String.to_integer(System.get_env("OBAN_QUEUE_EDGE") || "10"),
      integrations: String.to_integer(System.get_env("OBAN_QUEUE_INTEGRATIONS") || "5"),
      nats_accounts: String.to_integer(System.get_env("OBAN_QUEUE_NATS_ACCOUNTS") || "3"),
      # Ansible automation queues: catalog sync (AWX job templates + git
      # playbook repositories), run pulse/health/watchdog, and retention. The
      # workers declared these queues but they were never configured here, so
      # every ansible job (including git repository syncs) sat `available`
      # forever and catalog/pulse/retention never executed.
      ansible_catalog: String.to_integer(System.get_env("OBAN_QUEUE_ANSIBLE_CATALOG") || "4"),
      ansible_pulse: String.to_integer(System.get_env("OBAN_QUEUE_ANSIBLE_PULSE") || "4"),
      ansible_retention: String.to_integer(System.get_env("OBAN_QUEUE_ANSIBLE_RETENTION") || "1")
    ],
    plugins: [
      Oban.Plugins.Pruner,
      {Oban.Plugins.Lifeline, rescue_after: oban_lifeline_rescue_after_ms},
      {Oban.Plugins.Cron,
       crontab:
         [
           {System.get_env("TRACE_SUMMARIES_REFRESH_CRON") || "*/2 * * * *",
            RefreshTraceSummariesWorker, queue: :maintenance},
           {"*/5 * * * *", RootSpanRatioWorker, queue: :maintenance},
           {"*/15 * * * *", ServiceRadar.Jobs.ReapStalePeriodicJobsWorker, queue: :maintenance},
           {"17 * * * *", ServiceRadar.Jobs.PruneStaleAgentsWorker, queue: :maintenance},
           {"17 3 * * *", DataRetentionWorker, queue: :maintenance},
           # Cold-tier chunk exporter: hourly so the frontier stays ~export_lag
           # behind now; self-guards on cold-tier config (no-op when absent).
           # Correctness does NOT depend on running before DataRetentionWorker —
           # the fence's drop gate alone enforces export-before-drop.
           {"47 * * * *", ServiceRadar.ColdTier.Exporter, queue: :maintenance},
           # Cold-window pruning + manifest/bucket reconciliation (no-op when
           # cold-tier config is absent).
           {"23 4 * * *", ServiceRadar.ColdTier.Pruner, queue: :maintenance},
           {"*/10 * * * *", ServiceRadar.Edge.RemoteAccessRecordingReaperWorker,
            queue: :maintenance},
           {"31 3 * * *", ServiceRadar.Edge.RemoteAccessVersionRetentionWorker,
            queue: :maintenance},
           # Kept in step with the same entry in serviceradar_core_elx's
           # runtime.exs -- that one is what the release actually loads.
           {System.get_env("SERVICERADAR_CREDENTIAL_BROKER_RETENTION_CRON") || "43 3 * * *",
            ServiceRadar.Credentials.BrokerRetentionWorker, queue: :maintenance}
         ] ++
           object_store_retention_crontab ++
           capacity_forecasting_crontab ++
           ProductionSchedule.cron_entries() ++
           DispatchSchedule.cron_entries()}
    ],
    peer: Oban.Peers.Database

  config :serviceradar_core,
         SeasonalDispositionWorker,
         ProductionSchedule.seasonal_disposition_worker_config()

  # Operator-set stale thresholds for the scheduled anomaly workers; the
  # worker modules' own defaults apply when unset.
  for {key, value} <- ProductionSchedule.app_env() do
    config :serviceradar_core, key, value
  end

  config :serviceradar_core, :object_store_retention,
    enabled?: object_store_retention_enabled,
    dry_run?: object_store_retention_dry_run,
    agent_release_keep_latest:
      String.to_integer(System.get_env("OBJECT_STORE_RETENTION_AGENT_RELEASE_KEEP_LATEST") || "1"),
    native_addon_orphan_grace_seconds:
      String.to_integer(
        System.get_env("OBJECT_STORE_RETENTION_NATIVE_ADDON_ORPHAN_GRACE_SECONDS") || "604800"
      ),
    datasvc_timeout_ms:
      String.to_integer(System.get_env("OBJECT_STORE_RETENTION_DATASVC_TIMEOUT_MS") || "30000")

  if nats_enabled && nats_creds_file in [nil, ""] do
    raise """
    NATS_CREDS_FILE is required for NATS JWT auth.
    Generate or provision JWT credentials and set NATS_CREDS_FILE.
    """
  end

  nats_tls_config =
    if nats_tls_enabled do
      [
        verify: :verify_peer,
        cacertfile: Path.join(cert_dir, "root.pem"),
        certfile: Path.join(cert_dir, "core.pem"),
        keyfile: Path.join(cert_dir, "core-key.pem"),
        server_name_indication: String.to_charlist(nats_server_name)
      ]
    else
      false
    end

  log_promotion_enabled =
    System.get_env("LOG_PROMOTION_CONSUMER_ENABLED", "true") in ~w(true 1 yes)

  # EventWriter configuration (NATS JetStream → CNPG consumer).
  # Default ON when NATS creds are configured: the helm chart sets
  # EVENT_WRITER_ENABLED and EVENT_WRITER_NATS_CREDS_FILE together, so an UNSET flag
  # with creds present is a deploy drift that must still run the EventWriter (edge
  # anomaly verdicts have to persist to CNPG). Stays OFF with no creds so
  # credential-less dev/test deployments don't trip the creds-required raise below.
  event_writer_default =
    if System.get_env("EVENT_WRITER_NATS_CREDS_FILE") in [nil, ""], do: "false", else: "true"

  event_writer_enabled =
    System.get_env("EVENT_WRITER_ENABLED", event_writer_default) in ~w(true 1 yes)

  config :serviceradar_core, ServiceRadar.NATS.Connection,
    host: nats_uri.host || "localhost",
    port: nats_uri.port || 4222,
    user: System.get_env("NATS_USER"),
    password: {:system, "NATS_PASSWORD"},
    creds_file: nats_creds_file,
    tls: nats_tls_config

  config :serviceradar_core, :log_promotion_consumer_enabled, log_promotion_enabled

  if event_writer_enabled do
    event_writer_creds = System.get_env("EVENT_WRITER_NATS_CREDS_FILE")

    if event_writer_creds in [nil, ""] do
      raise """
      EVENT_WRITER_NATS_CREDS_FILE is required when EVENT_WRITER_ENABLED=true.
      Generate or provision JWT credentials and set EVENT_WRITER_NATS_CREDS_FILE.
      """
    end

    nats_url = System.get_env("EVENT_WRITER_NATS_URL", "nats://localhost:4222")
    nats_uri = URI.parse(nats_url)

    # Build TLS configuration for mTLS
    nats_tls_enabled = System.get_env("EVENT_WRITER_NATS_TLS", "false") in ~w(true 1 yes)
    cert_dir = System.get_env("SPIFFE_CERT_DIR", "/etc/serviceradar/certs")

    nats_tls_config =
      if nats_tls_enabled do
        [
          verify: :verify_peer,
          cacertfile: Path.join(cert_dir, "root.pem"),
          certfile: Path.join(cert_dir, "core.pem"),
          keyfile: Path.join(cert_dir, "core-key.pem"),
          server_name_indication: ~c"nats.serviceradar"
        ]
      else
        false
      end

    config :serviceradar_core, ServiceRadar.EventWriter,
      enabled: true,
      nats: [
        host: nats_uri.host || "localhost",
        port: nats_uri.port || 4222,
        user: System.get_env("EVENT_WRITER_NATS_USER"),
        password: {:system, "EVENT_WRITER_NATS_PASSWORD"},
        creds_file: event_writer_creds,
        tls: nats_tls_config
      ],
      batch_size: String.to_integer(System.get_env("EVENT_WRITER_BATCH_SIZE") || "100"),
      batch_timeout: String.to_integer(System.get_env("EVENT_WRITER_BATCH_TIMEOUT") || "1000"),
      consumer_name: System.get_env("EVENT_WRITER_CONSUMER_NAME", "serviceradar-event-writer"),
      # Flow control: pull consumers request bounded work only when Broadway has
      # demand. All tunable without a rebuild via env.
      consumer_pull_batch_size:
        String.to_integer(System.get_env("EVENT_WRITER_CONSUMER_PULL_BATCH_SIZE") || "16"),
      max_ack_pending: String.to_integer(System.get_env("EVENT_WRITER_MAX_ACK_PENDING") || "256"),
      processor_concurrency:
        String.to_integer(System.get_env("EVENT_WRITER_PROCESSOR_CONCURRENCY") || "10"),
      ack_wait_ns:
        String.to_integer(System.get_env("EVENT_WRITER_ACK_WAIT_SECONDS") || "120") *
          1_000_000_000,
      max_deliver: String.to_integer(System.get_env("EVENT_WRITER_MAX_DELIVER") || "5"),
      streams: [
        %{
          name: "EVENTS",
          subject: "events.>",
          processor: ServiceRadar.EventWriter.Processors.Events,
          batch_size: 100,
          batch_timeout: 1_000,
          # Retention guard: drop oldest if the consumer falls behind instead of
          # growing the shared `events` stream until core OOMs (8 GiB / 24h).
          stream_retention: "limits",
          stream_storage: "file",
          stream_discard: "old",
          stream_max_bytes: 8_589_934_592,
          stream_max_age: 86_400_000_000_000
        },
        %{
          name: "PDNS_OCSF",
          stream_name: "events",
          subject: "pdns.ocsf",
          processor: PowerDNS,
          batch_size: 100,
          batch_timeout: 1_000
        },
        %{
          name: "FALCO",
          stream_name: "events",
          subject: "falco.logs",
          processor: ServiceRadar.EventWriter.Processors.FalcoEvents,
          batch_size: 100,
          batch_timeout: 1_000
        },
        %{
          name: "TRIVY",
          stream_name: "trivy_reports",
          subject: "trivy.report.>",
          processor: ServiceRadar.EventWriter.Processors.TrivyReports,
          batch_size: 100,
          batch_timeout: 1_000
        },
        # Public VIP / Gateway ownership inventory (add-k8s-public-endpoint-inventory).
        %{
          name: "K8S_INVENTORY",
          stream_name: "k8s_inventory",
          subject: "inventory.k8s.public_endpoints",
          processor: ServiceRadar.EventWriter.Processors.K8sPublicEndpoints,
          batch_size: 1,
          batch_timeout: 2_000,
          stream_retention: "limits",
          stream_storage: "file",
          stream_discard: "old",
          stream_max_bytes: 1_073_741_824,
          stream_max_age: 86_400_000_000_000
        },
        Config.k8s_nodes_stream(),
        %{
          name: "OTEL_METRICS",
          subject: "otel.metrics.>",
          processor: ServiceRadar.EventWriter.Processors.OtelMetrics,
          batch_size: 100,
          batch_timeout: 1_000
        },
        %{
          name: "OTEL_TRACES",
          subject: "otel.traces.>",
          processor: ServiceRadar.EventWriter.Processors.OtelTraces,
          batch_size: 100,
          batch_timeout: 1_000
        },
        %{
          name: "LOGS",
          stream_name: "events",
          subject: "logs.>",
          processor: ServiceRadar.EventWriter.Processors.Logs,
          batch_size: 100,
          batch_timeout: 1_000
        },
        %{
          name: "METRICS",
          stream_name: "metrics",
          subject: "metrics.>",
          processor: ServiceRadar.EventWriter.Processors.Metrics,
          batch_size: 500,
          batch_timeout: 500,
          stream_retention: "limits",
          stream_storage: "file",
          stream_discard: "old",
          stream_max_bytes: 1_073_741_824,
          stream_max_age: 1_800_000_000_000,
          consumer_pull_batch_size: 4,
          consumer_max_deliver: 5
        },
        %{
          name: "SCAN_RESULTS",
          stream_name: "scan_results",
          subject: "scans.results.>",
          processor: ServiceRadar.EventWriter.Processors.AdhocScan,
          batch_size: 200,
          batch_timeout: 500,
          stream_retention: "limits",
          stream_storage: "file",
          stream_discard: "old",
          stream_max_bytes: 268_435_456,
          stream_max_age: 3_600_000_000_000
        },
        %{
          name: "BMP_CAUSAL",
          subject: "bmp.events.>",
          processor: AnalyticsSignals,
          batch_size: 100,
          batch_timeout: 1_000
        },
        %{
          name: "ARANCINI_CAUSAL",
          subject: "arancini.updates.>",
          processor: AnalyticsSignals,
          batch_size: 100,
          batch_timeout: 1_000
        },
        %{
          name: "SIEM_CAUSAL",
          subject: "siem.events.>",
          processor: AnalyticsSignals,
          batch_size: 100,
          batch_timeout: 1_000
        },
        # Dedicated anomaly/capacity verdict stream (restore-anomaly-alerting
        # design D9); definition shared with Config.default_streams/0 so the
        # retention stanza cannot drift.
        Config.analytics_predictions_stream()
      ],
      # Dedicated demand domain for raw flows on JetStream stream `flows`.
      # Optional EVENT_WRITER_FLOW_* tuning is applied below only when set so
      # per-stream custom values are not clobbered by release defaults.
      flow_streams: Config.default_flow_streams()

    # Optional flow pipeline overrides (env only — never inject hard-coded defaults).
    if v = System.get_env("EVENT_WRITER_FLOW_CONSUMER_PULL_BATCH_SIZE") do
      config :serviceradar_core, ServiceRadar.EventWriter,
        flow_consumer_pull_batch_size: String.to_integer(v)
    end

    if v = System.get_env("EVENT_WRITER_FLOW_MAX_ACK_PENDING") do
      config :serviceradar_core, ServiceRadar.EventWriter,
        flow_max_ack_pending: String.to_integer(v)
    end

    if v = System.get_env("EVENT_WRITER_FLOW_PULL_EXPIRES_NS") do
      config :serviceradar_core, ServiceRadar.EventWriter,
        flow_pull_expires_ns: String.to_integer(v)
    end

    config :serviceradar_core, :event_writer_enabled, true
  end
end

# Outbound mail.
#
# The adapter is derived from the environment in exactly one place -
# `ServiceRadar.OutboundMail.RuntimeConfig` - so this release and
# `serviceradar_core_elx` cannot resolve different mailers from the same
# variables. With nothing set it still resolves to `Swoosh.Adapters.Test`,
# which is what it did before; the difference is that
# `ServiceRadar.OutboundMail.diagnose/0` now names that state instead of
# letting every send report success.
if config_env() == :prod do
  mailer_env = System.get_env()

  config :serviceradar_core,
         ServiceRadar.Mailer,
         ServiceRadar.OutboundMail.RuntimeConfig.mailer_config(mailer_env)

  # Overrides the compile-time `false` in config.exs: an API adapter with no
  # HTTP client raises on every send, and config.exs cannot know which adapter
  # this deployment picked because it is chosen here. `Req` is already a
  # dependency, so this costs nothing when the adapter needs no HTTP client.
  config :swoosh, :api_client, Swoosh.ApiClient.Req
  config :swoosh, local: ServiceRadar.OutboundMail.RuntimeConfig.local?(mailer_env)
end
