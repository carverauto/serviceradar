import gleam/otp/actor

pub type MetricsCollectorState {
  MetricsCollectorState(
    polls_total: Int,
    polls_successful: Int,
    polls_failed: Int,
  )
}

pub type MetricsCollectorMessage {
  IncrementPollsTotal
  IncrementPollsSuccessful
  IncrementPollsFailed
  GetMetrics
  Shutdown
}

pub fn start() {
  let initial_state = MetricsCollectorState(
    polls_total: 0,
    polls_successful: 0,
    polls_failed: 0,
  )

  actor.new(initial_state)
  |> actor.on_message(handle_message)
  |> actor.start()
}

fn handle_message(
  state: MetricsCollectorState,
  message: MetricsCollectorMessage,
) -> actor.Next(MetricsCollectorState, MetricsCollectorMessage) {
  case message {
    IncrementPollsTotal -> {
      actor.continue(MetricsCollectorState(
        ..state,
        polls_total: state.polls_total + 1,
      ))
    }

    IncrementPollsSuccessful -> {
      actor.continue(MetricsCollectorState(
        ..state,
        polls_successful: state.polls_successful + 1,
      ))
    }

    IncrementPollsFailed -> {
      actor.continue(MetricsCollectorState(
        ..state,
        polls_failed: state.polls_failed + 1,
      ))
    }

    GetMetrics -> {
      // For now, just continue - in real implementation this would reply
      actor.continue(state)
    }

    Shutdown -> {
      actor.stop()
    }
  }
}