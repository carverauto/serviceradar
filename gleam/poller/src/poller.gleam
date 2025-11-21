import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import poller/agent_coordinator
import poller/config
import poller/core_service
import poller/supervisor
import poller/types.{AgentConfig, Check}

pub fn main() -> Nil {
  io.println("Starting ServiceRadar Gleam Poller MVP...")

  case start_poller() {
    Ok(_) -> io.println("Poller started successfully!")
    Error(error) -> {
      io.println("Failed to start poller: " <> error)
    }
  }
}

pub fn start_poller() -> Result(Nil, String) {
  // Create a sample configuration
  let demo_config =
    config.create_default_config()
    |> config.add_agent(
      "demo_agent",
      AgentConfig(
        address: "localhost:8080",
        checks: [
          Check(
            name: "agent_health",
            type_: "agent_health",
            agent_id: "demo_agent",
            poller_id: "gleam_poller_mvp",
            details: None,
            interval: 30_000,
          ),
          Check(
            name: "external_checkers",
            type_: "grpc_health",
            agent_id: "demo_agent",
            poller_id: "gleam_poller_mvp",
            details: None,
            interval: 60_000,
          ),
        ],
        security: None,
      ),
    )

  // Start OTP supervisor with all components
  use _started_supervisor <- result.try(
    supervisor.start(demo_config)
    |> result.map_error(fn(_) { "Failed to start OTP supervisor" }),
  )

  // Create and test agent coordinator
  use agent_coordinator_state <- result.try(
    agent_coordinator.create_agent_coordinator(
      "demo_agent",
      case config.get_agent(demo_config, "demo_agent") {
        option.Some(agent_config) -> agent_config
        option.None -> AgentConfig(address: "", checks: [], security: None)
      },
    )
    |> result.map_error(fn(_) { "Failed to create agent coordinator" }),
  )

  use connected_agent <- result.try(
    agent_coordinator.connect_agent(agent_coordinator_state)
    |> result.map_error(fn(_) { "Failed to connect to agent" }),
  )

  // Execute some service checks
  use health_check_result <- result.try(
    agent_coordinator.execute_check(
      connected_agent,
      Check(
        name: "agent_health",
        type_: "agent_health",
        agent_id: "demo_agent",
        poller_id: "gleam_poller_mvp",
        details: None,
        interval: 30_000,
      ),
    )
    |> result.map_error(fn(_) { "Failed to execute health check" }),
  )

  use db_check_result <- result.try(
    agent_coordinator.execute_check(
      connected_agent,
      Check(
        name: "external_checkers",
        type_: "grpc_health",
        agent_id: "demo_agent",
        poller_id: "gleam_poller_mvp",
        details: None,
        interval: 60_000,
      ),
    )
    |> result.map_error(fn(_) { "Failed to execute database check" }),
  )

  // Create core service channel and report results
  use core_channel <- result.try(
    core_service.create_core_channel(
      "localhost:9090",
      "gleam_poller_mvp",
      "partition_1",
      "127.0.0.1",
    )
    |> result.map_error(fn(_) { "Failed to create core channel" }),
  )

  use connected_core <- result.try(
    core_service.connect_core_channel(core_channel)
    |> result.map_error(fn(_) { "Failed to connect to core service" }),
  )

  // Try to report to core service, but don't fail if it's unavailable
  let report_result = core_service.report_status(
    connected_core,
    [health_check_result, db_check_result],
    demo_config,
  )

  case report_result {
    Ok(_) -> {
      io.println("Status reports sent to core")
    }
    Error(_) -> {
      io.println("Core service unavailable - poller will continue operating")
      io.println("  (Status reports will be retried automatically)")
    }
  }

  io.println("Configuration validated")
  io.println("OTP supervisor started (security, config watcher, metrics, core reporter)")
  io.println("Agent coordinator created")
  io.println("Agent connected")
  io.println("Service checks executed")
  io.println("Core service connection established")
  io.println("")
  io.println("ServiceRadar Gleam Poller started successfully")
  io.println("")
  io.println("Starting continuous polling loop...")
  io.println("Press Ctrl+C twice to stop (or type 'a' in debugger then Enter)")
  io.println("")

  // Start the continuous polling loop
  start_polling_loop(connected_agent, connected_core, demo_config)

  Ok(Nil)
}

/// Continuous polling loop that runs the poller service
fn start_polling_loop(
  agent_state: agent_coordinator.AgentCoordinatorState,
  core_channel: core_service.CoreChannel,
  config: types.Config,
) -> Nil {
  polling_loop(agent_state, core_channel, config, 1)
}

fn polling_loop(
  agent_state: agent_coordinator.AgentCoordinatorState,
  core_channel: core_service.CoreChannel,
  config: types.Config,
  cycle: Int,
) -> Nil {
  io.println("Polling cycle #" <> string.inspect(cycle) <> " starting...")

  // Execute all checks for this agent
  let check_results = case config.get_agent(config, "demo_agent") {
    Some(agent_config) -> {
      agent_config.checks
      |> list.map(fn(check) {
        case agent_coordinator.execute_check(agent_state, check) {
          Ok(result) -> {
            io.println("  " <> check.name <> ": " <> case result.available {
              True -> "UP"
              False -> "DOWN"
            })
            result
          }
          Error(_) -> {
            io.println("  " <> check.name <> ": ERROR")
            // Create a failure status
            types.ServiceStatus(
              service_name: check.name,
              available: False,
              message: "Check execution failed",
              service_type: check.type_,
              response_time: 30_000_000_000, // 30s timeout in nanoseconds
              agent_id: check.agent_id,
              poller_id: check.poller_id,
              timestamp: 0, // Will be updated by core service
            )
          }
        }
      })
    }
    None -> []
  }

  // Report to core service (with retry logic)
  case core_service.report_status(core_channel, check_results, config) {
    Ok(_) -> io.println("  Reported " <> string.inspect(list.length(check_results)) <> " status(es) to core")
    Error(_) -> io.println("  Core service still unavailable (retrying...)")
  }

  // Sleep for 30 seconds before next cycle
  io.println("  Sleeping 30s until next cycle...")
  io.println("")
  sleep_seconds(30_000) // 30 seconds in milliseconds

  // Continue the loop
  polling_loop(agent_state, core_channel, config, cycle + 1)
}


// Sleep function for milliseconds
@external(erlang, "timer", "sleep")
fn sleep_seconds(milliseconds: Int) -> Nil
