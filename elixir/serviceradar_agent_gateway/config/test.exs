import Config

# Disable Swoosh API client in tests (no hackney needed)
config :swoosh, :api_client, false

# Use Test adapter for mailer
config :serviceradar_core, ServiceRadar.Mailer, adapter: Swoosh.Adapters.Test

# Disable Repo, Oban, clustering, and registries for standalone agent gateway tests (no database needed)
config :serviceradar_core,
  repo_enabled: false,
  cluster_enabled: false,
  registries_enabled: false

config :serviceradar_core, Oban, false

# Disable libcluster in tests
config :libcluster, topologies: []

# Disable domain warnings
config :ash, :validate_domain_config_inclusion?, false

# Test-specific configuration
config :logger, level: :warning

# Allow insecure gRPC in tests (no mTLS certs)
config :serviceradar_agent_gateway, :allow_insecure_grpc, true
