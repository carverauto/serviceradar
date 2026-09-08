import Config

# Hot-path per-message logs (StatusHandler/ResultsRouter, EventWriter decode
# paths) are demoted to lazy Logger.debug, so :info keeps useful breadcrumbs
# WITHOUT the self-telemetry storm. Self-telemetry stays on by default; the
# telemetry-on-telemetry feedback loop is broken at the OTel layer (root sampler
# + collector self-telemetry denylist), not by silencing logs. The hot-path
# debug lines stay runtime-tunable via SERVICERADAR_LOG_LEVEL (see runtime.exs).
config :logger, level: :info

# Swoosh defaults to its Hackney API client, but core-elx intentionally does not
# ship Hackney because its h2 modules conflict with grpcbox's chatterbox. Req is
# already a direct production dependency and is Swoosh's supported API client.
config :swoosh, :api_client, Swoosh.ApiClient.Req
