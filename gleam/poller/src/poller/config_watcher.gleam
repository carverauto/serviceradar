import gleam/otp/actor

pub type ConfigWatcherState {
  ConfigWatcherState(
    watching: Bool,
  )
}

pub type ConfigWatcherMessage {
  StartWatching
  StopWatching
  Shutdown
}

pub fn start() {
  let initial_state = ConfigWatcherState(watching: False)

  actor.new(initial_state)
  |> actor.on_message(handle_message)
  |> actor.start()
}

fn handle_message(
  _state: ConfigWatcherState,
  message: ConfigWatcherMessage,
) -> actor.Next(ConfigWatcherState, ConfigWatcherMessage) {
  case message {
    StartWatching -> {
      actor.continue(ConfigWatcherState(watching: True))
    }

    StopWatching -> {
      actor.continue(ConfigWatcherState(watching: False))
    }

    Shutdown -> {
      actor.stop()
    }
  }
}