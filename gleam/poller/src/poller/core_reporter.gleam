import gleam/otp/actor
import gleam/list
import poller/types.{type ServiceStatus}

pub type CoreReporterState {
  CoreReporterState(
    connected: Bool,
    buffer: List(ServiceStatus),
    batch_size: Int,
  )
}

pub type CoreReporterMessage {
  Connect
  Disconnect
  ReportStatus(ServiceStatus)
  SendBatch
  Shutdown
}

pub fn start() {
  let initial_state = CoreReporterState(
    connected: False,
    buffer: [],
    batch_size: 100,
  )

  actor.new(initial_state)
  |> actor.on_message(handle_message)
  |> actor.start()
}

fn handle_message(
  state: CoreReporterState,
  message: CoreReporterMessage,
) -> actor.Next(CoreReporterState, CoreReporterMessage) {
  case message {
    Connect -> {
      actor.continue(CoreReporterState(..state, connected: True))
    }

    Disconnect -> {
      actor.continue(CoreReporterState(..state, connected: False))
    }

    ReportStatus(status) -> {
      let new_buffer = [status, ..state.buffer]
      let new_state = CoreReporterState(..state, buffer: new_buffer)

      case list.length(new_buffer) >= state.batch_size {
        True -> {
          // Send batch and clear buffer
          // For now, just clear the buffer
          actor.continue(CoreReporterState(..new_state, buffer: []))
        }
        False -> {
          actor.continue(new_state)
        }
      }
    }

    SendBatch -> {
      // For now, just clear the buffer
      actor.continue(CoreReporterState(..state, buffer: []))
    }

    Shutdown -> {
      actor.stop()
    }
  }
}