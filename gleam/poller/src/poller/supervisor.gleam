import gleam/otp/static_supervisor as supervisor
import gleam/otp/supervision
import poller/types.{type Config}
import poller/config
import security/manager as security_manager
import poller/config_watcher
import poller/metrics_collector
import poller/core_reporter

pub type SupervisorError {
  SupervisorStartError(String)
}

pub fn start(_config: Config) {
  // Use static supervisor with OneForOne strategy
  supervisor.new(supervisor.OneForOne)
  |> supervisor.add(supervision.worker(security_manager.start))
  |> supervisor.add(supervision.worker(config_watcher.start))
  |> supervisor.add(supervision.worker(metrics_collector.start))
  |> supervisor.add(supervision.worker(core_reporter.start))
  |> supervisor.start()
}

pub fn start_link() {
  // For now, use a default config - this will be replaced with proper config loading
  let default_config = config.create_default_config()
  start(default_config)
}