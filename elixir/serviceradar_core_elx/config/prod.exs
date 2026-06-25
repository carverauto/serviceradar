import Config

# Default production level is :warning to avoid the per-message Logger.info
# self-telemetry storm on the hot ingestion paths (StatusHandler/ResultsRouter).
# Tunable at runtime without a rebuild via SERVICERADAR_LOG_LEVEL (see runtime.exs).
config :logger,
  level: :warning,
  # Never compile log calls below :info into the release, so debug-level
  # strings in hot decode/parse paths are not even built before filtering.
  compile_time_purge_matching: [[level_lower_than: :info]]
