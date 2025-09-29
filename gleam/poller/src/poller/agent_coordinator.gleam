import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import poller/grpc_client.{type GrpcChannel}
import poller/types.{
  type AgentConfig, type AgentConnectionState, type Check, type CircuitState,
  type ServiceStatus, Closed, Connected,
  Disconnected, Failed, Open,
}

// NOTE: This agent coordinator currently uses gRPC for communication,
// but in the final architecture, agents will communicate via GenServer/actor messages.
// gRPC is only for communication with the core service.
// The new Gleam-based agents will speak gRPC to other components,
// but the poller will communicate with agents via GenServer.

pub type AgentCoordinatorState {
  AgentCoordinatorState(
    agent_name: String,
    config: AgentConfig,
    connection_state: AgentConnectionState,
    circuit_state: CircuitState,
    failure_count: Int,
    last_poll_time: Int,
    grpc_channel: Option(GrpcChannel),
    // TODO: Replace with GenServer Subject when agents are migrated
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
        grpc_channel: None,
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
      // Create and connect gRPC channel
      use channel <- result.try(
        grpc_client.create_channel(state.config.address)
        |> result.map_error(fn(_) {
          ConnectionFailed("Failed to create gRPC channel")
        }),
      )

      case grpc_client.connect_channel(channel) {
        Ok(connected_channel) ->
          Ok(
            AgentCoordinatorState(
              ..state,
              connection_state: Connected,
              failure_count: 0,
              grpc_channel: Some(connected_channel),
            ),
          )
        Error(_error) -> {
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
              grpc_channel: None,
            ),
          )
        }
      }
    }
  }
}

pub fn disconnect_agent(state: AgentCoordinatorState) -> AgentCoordinatorState {
  AgentCoordinatorState(
    ..state,
    connection_state: Disconnected,
    grpc_channel: None,
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
          case state.grpc_channel {
            Some(channel) -> {
              let request = grpc_client.service_check_to_status_request(check)
              case grpc_client.get_status(channel, request) {
                Ok(response) ->
                  Ok(grpc_client.status_response_to_service_status(response))
                Error(_error) -> Error(ConnectionFailed("gRPC call failed"))
              }
            }
            None -> Error(ConnectionFailed("No gRPC channel available"))
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
