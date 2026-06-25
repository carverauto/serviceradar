import Config

# Production configuration is typically set via runtime.exs
# This file is for compile-time production settings only

# Hot-path per-message logs are demoted to lazy Logger.debug, so :info keeps
# useful breadcrumbs WITHOUT the self-telemetry storm. Self-telemetry stays on
# by default; the telemetry-on-telemetry feedback loop is broken at the OTel
# layer (root sampler + collector self-telemetry denylist), not by silencing
# logs. Tunable at runtime via SERVICERADAR_LOG_LEVEL (see runtime.exs).
config :logger, level: :info
