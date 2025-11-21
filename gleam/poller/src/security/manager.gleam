import gleam/otp/actor
import gleam/option
import poller/types.{type SecurityConfig, SecurityConfig, Disabled}

pub type SecurityManagerState {
  SecurityManagerState(
    initialized: Bool,
    security_config: SecurityConfig,
  )
}

pub type SecurityManagerMessage {
  GetSecurityConfig
  UpdateSecurityConfig(SecurityConfig)
  Shutdown
}

pub fn start() {
  let initial_state = SecurityManagerState(
    initialized: True,
    security_config: SecurityConfig(
      tls: option.None,
      mode: Disabled,
    ),
  )

  actor.new(initial_state)
  |> actor.on_message(handle_message)
  |> actor.start()
}

fn handle_message(
  state: SecurityManagerState,
  message: SecurityManagerMessage,
) -> actor.Next(SecurityManagerState, SecurityManagerMessage) {
  case message {
    GetSecurityConfig -> {
      // For now, just continue - in a real implementation this would reply
      actor.continue(state)
    }

    UpdateSecurityConfig(new_config) -> {
      let new_state = SecurityManagerState(
        ..state,
        security_config: new_config,
      )
      actor.continue(new_state)
    }

    Shutdown -> {
      actor.stop()
    }
  }
}