import Config

# Disable domain warnings
config :ash, :validate_domain_config_inclusion?, false

# Disable libcluster in tests
config :libcluster, topologies: []

# Test-specific configuration
config :logger, level: :warning

config :serviceradar_agent_gateway,
  gateway_cert_dir: Path.expand("../test/support/certs", __DIR__),
  gateway_grpc_port: 58_052,
  gateway_artifact_port: 58_053

config :serviceradar_core, Oban, false

# Use Test adapter for mailer
config :serviceradar_core, ServiceRadar.Mailer, adapter: Swoosh.Adapters.Test

# Disable Repo, Oban, clustering, and registries for standalone agent gateway tests (no database needed)
config :serviceradar_core,
  repo_enabled: false,
  cluster_enabled: false,
  registries_enabled: false

# Disable Swoosh API client in tests (no hackney needed)
config :swoosh, :api_client, false
