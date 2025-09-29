import gleam/list
import gleam/option.{type Option, None, Some}
import poller/types.{
  type AgentConfig, type AgentConnectionState, type Check, type CircuitState,
  type ServiceStatus, Closed, Connected,
  Disconnected, Failed, Open, ServiceStatus,
}

/// Agent Coordinator Module
///
/// Architecture:
/// - Poller ↔ Agent: Uses GenServer/Actor messages (this module)
/// - Poller → Core Service: Uses gRPC (see core_service.gleam)
/// - Agent → External Checkers/Plugins: Uses gRPC (handled by individual agents)
///
/// This module manages communication between the poller and agents using
/// Gleam's actor model. Agents themselves will use gRPC to communicate
/// with external checkers and plugins written in other languages.

/// Messages that can be sent to an agent
/// Note: Subject type requires gleam_erlang package which we'll add when implementing real actors
pub type AgentMessage {
  ExecuteCheck(Check)  // Simplified for now without Subject
  GetStatus
  Shutdown
}

/// Agent status information
pub type AgentStatus {
  AgentStatus(
    agent_name: String,
    connection_state: AgentConnectionState,
    circuit_state: CircuitState,
    failure_count: Int,
    last_poll_time: Int,
  )
}

pub type AgentCoordinatorState {
  AgentCoordinatorState(
    agent_name: String,
    config: AgentConfig,
    connection_state: AgentConnectionState,
    circuit_state: CircuitState,
    failure_count: Int,
    last_poll_time: Int,
    agent_subject: Option(AgentMessage),  // Will be Option(Subject(AgentMessage)) when actors are available
    // Subject for sending messages to the agent actor
  )
}

pub type AgentCoordinatorError {
  ConnectionFailed(String)
  InvalidConfiguration(String)
  CircuitBreakerOpen
}

pub type ConnectionManager {
  ConnectionManager(address: String, connected: Bool, failure_count: Int)
}

pub fn create_agent_coordinator(
  agent_name: String,
  config: AgentConfig,
) -> Result(AgentCoordinatorState, AgentCoordinatorError) {
  case validate_agent_config(config) {
    Ok(_) ->
      Ok(AgentCoordinatorState(
        agent_name: agent_name,
        config: config,
        connection_state: Disconnected,
        circuit_state: Closed,
        failure_count: 0,
        last_poll_time: 0,
        agent_subject: None,
      ))
    Error(error) -> Error(InvalidConfiguration(error))
  }
}

pub fn connect_agent(
  state: AgentCoordinatorState,
) -> Result(AgentCoordinatorState, AgentCoordinatorError) {
  case state.circuit_state {
    Open -> Error(CircuitBreakerOpen)
    _ -> {
      // Start the agent actor (GenServer)
      // In a real implementation, this would spawn an agent actor process
      // For now, we'll simulate the connection

      // TODO: Spawn actual agent actor using gleam/otp when available
      // let agent_subject = agent.start(state.config)

      // Simulate failure for testing
      case state.config.address {
        "fail" -> {
          let new_failure_count = state.failure_count + 1
          let new_circuit_state = case new_failure_count >= 5 {
            True -> Open
            False -> state.circuit_state
          }
          Ok(
            AgentCoordinatorState(
              ..state,
              connection_state: Failed,
              failure_count: new_failure_count,
              circuit_state: new_circuit_state,
              agent_subject: None,
            ),
          )
        }
        _ ->
          Ok(
            AgentCoordinatorState(
              ..state,
              connection_state: Connected,
              failure_count: 0,
              agent_subject: Some(GetStatus),  // Placeholder until real actor is spawned
            ),
          )
      }
    }
  }
}

pub fn disconnect_agent(state: AgentCoordinatorState) -> AgentCoordinatorState {
  // Send shutdown message to agent if connected
  // TODO: Implement when actor system is available
  // case state.agent_subject {
  //   Some(subject) -> process.send(subject, Shutdown)
  //   None -> Nil
  // }

  AgentCoordinatorState(
    ..state,
    connection_state: Disconnected,
    agent_subject: None,
  )
}

pub fn execute_check(
  state: AgentCoordinatorState,
  check: Check,
) -> Result(ServiceStatus, AgentCoordinatorError) {
  case state.connection_state {
    Connected -> {
      case state.circuit_state {
        Open -> Error(CircuitBreakerOpen)
        _ -> {
          case state.agent_subject {
            Some(_subject) -> {
              // Send check request to agent actor via message passing
              // The agent will use gRPC to communicate with external checkers
              // For now, return a simulated response

              // TODO: Implement actual message passing when actor is available
              // let reply_subject = process.new_subject()
              // process.send(subject, ExecuteCheck(check, reply_subject))
              // process.receive(reply_subject, timeout_ms: 30000)

              // Simulated response for testing
              Ok(ServiceStatus(
                service_name: check.name,
                available: True,
                message: "Service is healthy (simulated)",
                service_type: check.type_,
                response_time: 50_000_000,
                agent_id: check.agent_id,
                poller_id: check.poller_id,
                timestamp: 1_640_000_000,
              ))
            }
            None -> Error(ConnectionFailed("No agent actor available"))
          }
        }
      }
    }
    _ -> Error(ConnectionFailed("Agent not connected"))
  }
}

pub fn get_connection_state(
  state: AgentCoordinatorState,
) -> AgentConnectionState {
  state.connection_state
}

pub fn get_circuit_state(state: AgentCoordinatorState) -> CircuitState {
  state.circuit_state
}

pub fn get_failure_count(state: AgentCoordinatorState) -> Int {
  state.failure_count
}

pub fn reset_circuit_breaker(
  state: AgentCoordinatorState,
) -> AgentCoordinatorState {
  AgentCoordinatorState(..state, circuit_state: Closed, failure_count: 0)
}

fn validate_agent_config(config: AgentConfig) -> Result(Nil, String) {
  case config.address {
    "" -> Error("Agent address cannot be empty")
    _ -> {
      case list.is_empty(config.checks) {
        True -> Error("Agent must have at least one check")
        False -> Ok(Nil)
      }
    }
  }
}
