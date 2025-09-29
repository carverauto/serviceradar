import gleam/option.{type Option, None}
import gleam/string
import poller/types.{
  type Check, type GrpcError, type ServiceStatus, ConnectionError, ServiceStatus,
  TimeoutError,
}

/// gRPC client interface for external checker/plugin communication.
///
/// This module is used by agents to communicate with external checkers
/// and plugins written in other languages (Go, Rust, Python, etc.).
///
/// Architecture:
/// - Agent → External Checkers: Uses gRPC (this module)
/// - Poller ↔ Agent: Uses GenServer/Actor messages (see agent_coordinator.gleam)
/// - Poller → Core Service: Uses gRPC (see core_service.gleam)
///
/// gRPC channel for communicating with external checkers and plugins
pub type GrpcChannel {
  GrpcChannel(address: String, connected: Bool, options: GrpcChannelOptions)
}

/// Configuration options for gRPC connections
pub type GrpcChannelOptions {
  GrpcChannelOptions(timeout_ms: Int, max_retry_attempts: Int, insecure: Bool)
}

/// Request to check the status of a service on an agent
pub type StatusRequest {
  StatusRequest(
    service_name: String,
    service_type: String,
    agent_id: String,
    poller_id: String,
    details: Option(String),
    port: Option(Int),
  )
}

/// Response containing the status of a service from an agent
pub type StatusResponse {
  StatusResponse(
    available: Bool,
    message: String,
    service_name: String,
    service_type: String,
    response_time: Int,
    agent_id: String,
    poller_id: String,
    timestamp: Int,
  )
}

/// Create a new gRPC channel for external checker communication
///
/// ## Parameters
///
/// - `address`: gRPC address of the external checker (e.g. "localhost:8080")
///
/// ## Returns
///
/// Returns `Ok(GrpcChannel)` if the address is valid, otherwise `Error(GrpcError)`
pub fn create_channel(address: String) -> Result(GrpcChannel, GrpcError) {
  case string.is_empty(address) {
    True -> Error(ConnectionError("Address cannot be empty"))
    False ->
      Ok(GrpcChannel(
        address: address,
        connected: False,
        options: GrpcChannelOptions(
          timeout_ms: 30_000,
          max_retry_attempts: 3,
          insecure: True,
          // For development - should be False in production
        ),
      ))
  }
}

/// Establish a connection to an external checker
///
/// ## Parameters
///
/// - `channel`: GrpcChannel to connect
///
/// ## Returns
///
/// Returns `Ok(GrpcChannel)` with connected=True if successful, otherwise `Error(GrpcError)`
pub fn connect_channel(channel: GrpcChannel) -> Result(GrpcChannel, GrpcError) {
  // TODO: Implement real protozoa connection to external checker
  case validate_checker_address(channel.address) {
    Ok(_) -> Ok(GrpcChannel(..channel, connected: True))
    Error(error) -> Error(error)
  }
}

/// Execute a service status check via an external checker
///
/// ## Parameters
///
/// - `channel`: Connected GrpcChannel
/// - `request`: StatusRequest with service details to check
///
/// ## Returns
///
/// Returns `Ok(StatusResponse)` with service status, otherwise `Error(GrpcError)`
pub fn get_status(
  channel: GrpcChannel,
  request: StatusRequest,
) -> Result(StatusResponse, GrpcError) {
  case channel.connected {
    False -> Error(ConnectionError("Channel not connected"))
    True -> {
      // TODO: Implement real protozoa gRPC call to CheckerService.GetStatus
      case call_checker_get_status(channel.address, request) {
        Ok(response) -> Ok(response)
        Error(error) -> Error(error)
      }
    }
  }
}

/// Convert a gRPC StatusResponse to our internal ServiceStatus type
///
/// ## Parameters
///
/// - `response`: StatusResponse from agent gRPC call
///
/// ## Returns
///
/// Returns ServiceStatus for internal processing
pub fn status_response_to_service_status(
  response: StatusResponse,
) -> ServiceStatus {
  ServiceStatus(
    service_name: response.service_name,
    available: response.available,
    message: response.message,
    service_type: response.service_type,
    response_time: response.response_time,
    agent_id: response.agent_id,
    poller_id: response.poller_id,
    timestamp: response.timestamp,
  )
}

/// Convert our internal Check type to a gRPC StatusRequest
///
/// ## Parameters
///
/// - `check`: Check configuration from agent config
///
/// ## Returns
///
/// Returns StatusRequest for gRPC call to agent
pub fn service_check_to_status_request(check: Check) -> StatusRequest {
  StatusRequest(
    service_name: check.name,
    service_type: check.type_,
    agent_id: check.agent_id,
    poller_id: check.poller_id,
    details: check.details,
    port: None,
    // TODO: Extract port from details if needed
  )
}

// Helper functions

/// Validate that a checker address has the correct format
fn validate_checker_address(address: String) -> Result(Nil, GrpcError) {
  case string.contains(address, ":") && !string.is_empty(address) {
    True -> Ok(Nil)
    False -> Error(ConnectionError("Invalid checker address format: " <> address))
  }
}

// Real gRPC implementation functions
// TODO: These will be implemented with protozoa once we have the protobuf definitions

/// Call the external checker CheckerService.GetStatus RPC
fn call_checker_get_status(
  _address: String,
  request: StatusRequest,
) -> Result(StatusResponse, GrpcError) {
  // TODO: Implement real protozoa gRPC call to CheckerService.GetStatus
  // For now, return a simulated response based on service name for testing
  case request.service_name {
    "fail-service" -> Error(ConnectionError("Service check failed"))
    "timeout-service" -> Error(TimeoutError)
    _ ->
      Ok(StatusResponse(
        available: True,
        message: "Service is healthy",
        service_name: request.service_name,
        service_type: request.service_type,
        response_time: 50_000_000,
        // 50ms in nanoseconds
        agent_id: request.agent_id,
        poller_id: request.poller_id,
        timestamp: 1_640_000_000,
        // Simulated timestamp
      ))
  }
}
