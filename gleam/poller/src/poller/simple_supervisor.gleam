import poller/config
import poller/types.{type Config}

pub type SupervisorError {
  SupervisorStartError(String)
}

pub type SupervisorState {
  SupervisorState(config: Config, started: Bool)
}

pub fn create_supervisor(
  config: Config,
) -> Result(SupervisorState, SupervisorError) {
  case config.validate_config(config) {
    Ok(valid_config) ->
      Ok(SupervisorState(config: valid_config, started: False))
    Error(_) -> Error(SupervisorStartError("Invalid configuration"))
  }
}

pub fn start_supervisor(
  state: SupervisorState,
) -> Result(SupervisorState, SupervisorError) {
  Ok(SupervisorState(..state, started: True))
}

pub fn stop_supervisor(
  state: SupervisorState,
) -> Result(SupervisorState, SupervisorError) {
  Ok(SupervisorState(..state, started: False))
}

pub fn is_running(state: SupervisorState) -> Bool {
  state.started
}

pub fn get_config(state: SupervisorState) -> Config {
  state.config
}
