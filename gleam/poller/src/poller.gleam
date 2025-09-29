import gleam/io
import gleam/option.{None}
import gleam/result
import poller/agent_coordinator
import poller/config
import poller/core_service
import poller/simple_supervisor
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
            name: "health_check",
            type_: "http",
            agent_id: "demo_agent",
            poller_id: "gleam_poller_mvp",
            details: None,
            interval: 30_000,
          ),
          Check(
            name: "database_check",
            type_: "postgres",
            agent_id: "demo_agent",
            poller_id: "gleam_poller_mvp",
            details: None,
            interval: 60_000,
          ),
        ],
        security: None,
      ),
    )

  // Validate and start supervisor
  use supervisor_state <- result.try(
    simple_supervisor.create_supervisor(demo_config)
    |> result.map_error(fn(_) { "Failed to create supervisor" }),
  )

  use _started_supervisor <- result.try(
    simple_supervisor.start_supervisor(supervisor_state)
    |> result.map_error(fn(_) { "Failed to start supervisor" }),
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
        name: "health_check",
        type_: "http",
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
        name: "database_check",
        type_: "postgres",
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

  use _report_result <- result.try(
    core_service.report_status(
      connected_core,
      [health_check_result, db_check_result],
      demo_config,
    )
    |> result.map_error(fn(_) { "Failed to report status to core" }),
  )

  io.println("✓ Configuration validated")
  io.println("✓ Supervisor started")
  io.println("✓ Agent coordinator created")
  io.println("✓ Agent connected")
  io.println("✓ Service checks executed")
  io.println("✓ Core service connection established")
  io.println("✓ Status reports sent to core")
  io.println("")
  io.println("🎉 ServiceRadar Gleam Poller MVP is fully operational!")
  io.println("")
  io.println("Architecture Notes:")
  io.println("- gRPC client communicates with existing Go agents (temporary)")
  io.println("- Core service communication via gRPC (production ready)")
  io.println("- Future: Agent communication will use GenServer/actors")
  io.println("- Future: New Gleam agents will speak gRPC to other components")

  Ok(Nil)
}
