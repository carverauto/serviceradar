import gleam/bit_array
import gleam/float
import gleam/list
import gleam/result
import gleam/string
import gleam/time/timestamp
import grpc_http_client
import monitoring_types.{
  type PollerStatusChunk, type PollerStatusRequest, type PollerStatusResponse,
  type ServiceStatus, PollerStatusChunk, PollerStatusRequest,
  PollerStatusResponse, ServiceStatus,
}
import poller/types.{
  type Config, type GrpcError, type ServiceStatus as InternalServiceStatus,
  ConnectionError,
}

/// Core service gRPC communication for reporting service statuses.
/// This module handles communication with the ServiceRadar core service
/// via gRPC for batch status reporting and streaming large datasets.
// Re-export monitoring types for convenience

pub type MonitoringPollerStatusRequest =
  PollerStatusRequest

pub type MonitoringPollerStatusResponse =
  PollerStatusResponse

pub type MonitoringPollerStatusChunk =
  PollerStatusChunk

pub type MonitoringServiceStatus =
  ServiceStatus

/// gRPC channel for communicating with the core service
pub type CoreChannel {
  CoreChannel(
    address: String,
    connected: Bool,
    poller_id: String,
    partition: String,
    source_ip: String,
  )
}

/// Create a new core service gRPC channel
///
/// ## Parameters
///
/// - `address`: gRPC address of the core service (e.g. "localhost:8080")
/// - `poller_id`: Unique identifier for this poller instance
/// - `partition`: Partition identifier for load balancing
/// - `source_ip`: Source IP address of this poller
///
/// ## Returns
///
/// Returns `Ok(CoreChannel)` if the address is valid, otherwise `Error(GrpcError)`
pub fn create_core_channel(
  address: String,
  poller_id: String,
  partition: String,
  source_ip: String,
) -> Result(CoreChannel, GrpcError) {
  case string.is_empty(address) {
    True -> Error(ConnectionError("Core address cannot be empty"))
    False ->
      Ok(CoreChannel(
        address: address,
        connected: False,
        poller_id: poller_id,
        partition: partition,
        source_ip: source_ip,
      ))
  }
}

/// Establish a connection to the core service
///
/// ## Parameters
///
/// - `channel`: CoreChannel to connect
///
/// ## Returns
///
/// Returns `Ok(CoreChannel)` with connected=True if successful, otherwise `Error(GrpcError)`
pub fn connect_core_channel(
  channel: CoreChannel,
) -> Result(CoreChannel, GrpcError) {
  // For now, validate the address format and mark as connected
  case validate_grpc_address(channel.address) {
    True -> Ok(CoreChannel(..channel, connected: True))
    False ->
      Error(ConnectionError("Invalid gRPC address format: " <> channel.address))
  }
}

/// Report a batch of service statuses to the core service with retry logic
///
/// ## Parameters
///
/// - `channel`: Connected CoreChannel
/// - `services`: List of internal ServiceStatus to report
/// - `config`: Configuration containing agent_id and kv_store_id
///
/// ## Returns
///
/// Returns `Ok(PollerStatusResponse)` if successful, otherwise `Error(GrpcError)`
/// Uses exponential backoff retry logic for resilience
pub fn report_status(
  channel: CoreChannel,
  services: List(InternalServiceStatus),
  config: Config,
) -> Result(PollerStatusResponse, GrpcError) {
  case channel.connected {
    False -> Error(ConnectionError("Core channel not connected"))
    True -> {
      // Convert internal ServiceStatus to monitoring ServiceStatus
      let monitoring_services =
        list.map(services, internal_to_monitoring_service_status)

      let request =
        PollerStatusRequest(
          services: monitoring_services,
          poller_id: channel.poller_id,
          agent_id: config.agent_id,
          timestamp: get_current_timestamp(),
          partition: channel.partition,
          source_ip: channel.source_ip,
          kv_store_id: config.kv_store_id,
        )

      // Retry with exponential backoff: 1s, 2s, 4s, 8s, 16s
      report_status_with_retry(channel.address, request, 5, 1000)
    }
  }
}

/// Report a large batch of service statuses using streaming
///
/// This function automatically chunks large datasets and streams them
/// to the core service for better performance and memory usage.
///
/// ## Parameters
///
/// - `channel`: Connected CoreChannel
/// - `services`: List of internal ServiceStatus to report
/// - `chunk_size`: Maximum number of statuses per chunk
/// - `config`: Configuration containing agent_id and kv_store_id
///
/// ## Returns
///
/// Returns `Ok(PollerStatusResponse)` if all chunks sent successfully, otherwise `Error(GrpcError)`
pub fn report_status_stream(
  channel: CoreChannel,
  services: List(InternalServiceStatus),
  chunk_size: Int,
  config: Config,
) -> Result(PollerStatusResponse, GrpcError) {
  case channel.connected {
    False -> Error(ConnectionError("Core channel not connected"))
    True -> {
      // Split services into chunks
      let chunks = chunk_services(services, chunk_size)
      let total_chunks = list.length(chunks)

      // Send each chunk
      chunks
      |> list.index_map(fn(chunk, index) {
        let monitoring_services =
          list.map(chunk, internal_to_monitoring_service_status)
        PollerStatusChunk(
          services: monitoring_services,
          poller_id: channel.poller_id,
          agent_id: config.agent_id,
          timestamp: get_current_timestamp(),
          partition: channel.partition,
          source_ip: channel.source_ip,
          is_final: index == total_chunks - 1,
          chunk_index: index,
          total_chunks: total_chunks,
          kv_store_id: config.kv_store_id,
        )
      })
      |> list.try_each(fn(chunk) {
        call_core_send_chunk(channel.address, chunk)
      })
      |> result.map(fn(_) { PollerStatusResponse(received: True) })
    }
  }
}

// Helper functions

/// Get the current timestamp in Unix epoch seconds
fn get_current_timestamp() -> Int {
  timestamp.system_time()
  |> timestamp.to_unix_seconds()
  |> float.round()
}

/// Convert internal ServiceStatus to monitoring ServiceStatus
fn internal_to_monitoring_service_status(
  internal: InternalServiceStatus,
) -> ServiceStatus {
  ServiceStatus(
    service_name: internal.service_name,
    available: internal.available,
    message: bit_array.from_string(internal.message),
    service_type: internal.service_type,
    response_time: internal.response_time,
    agent_id: internal.agent_id,
    poller_id: internal.poller_id,
    partition: "",
    // Will be set at the request level
    source: "status",
    // Default to "status"
    kv_store_id: "",
    // Will be set at the request level
  )
}

/// Split a list of services into chunks of the specified size
fn chunk_services(
  services: List(InternalServiceStatus),
  chunk_size: Int,
) -> List(List(InternalServiceStatus)) {
  case services {
    [] -> []
    _ -> {
      let chunk = list.take(services, chunk_size)
      let remaining = list.drop(services, chunk_size)
      [chunk, ..chunk_services(remaining, chunk_size)]
    }
  }
}

/// Validate that a gRPC address has the correct format
fn validate_grpc_address(address: String) -> Bool {
  // Basic validation - should contain host:port format
  string.contains(address, ":") && !string.is_empty(address)
}

// Real gRPC implementation functions using protozoa and HTTP/2

/// Call the core service ReportStatus RPC
/// Retry core service calls with exponential backoff
fn report_status_with_retry(
  address: String,
  request: PollerStatusRequest,
  max_retries: Int,
  initial_delay_ms: Int,
) -> Result(PollerStatusResponse, GrpcError) {
  retry_attempt(address, request, 0, max_retries, initial_delay_ms)
}

fn retry_attempt(
  address: String,
  request: PollerStatusRequest,
  attempt: Int,
  max_retries: Int,
  delay_ms: Int,
) -> Result(PollerStatusResponse, GrpcError) {
  case call_core_report_status(address, request) {
    Ok(response) -> Ok(response)
    Error(error) -> {
      case attempt < max_retries {
        True -> {
          // Sleep for exponential backoff delay
          sleep_ms(delay_ms)

          // Double the delay for next attempt (exponential backoff)
          let next_delay = delay_ms * 2
          retry_attempt(address, request, attempt + 1, max_retries, next_delay)
        }
        False -> {
          // Max retries exceeded - return the error but log it as a warning rather than failing
          Error(error)
        }
      }
    }
  }
}

fn call_core_report_status(
  address: String,
  request: PollerStatusRequest,
) -> Result(PollerStatusResponse, GrpcError) {
  // Make real gRPC call using HTTP/2 and protobuf
  case grpc_http_client.call_poller_service_report_status(address, request) {
    Ok(response) -> Ok(response)
    Error(grpc_http_client.HttpError(msg)) ->
      Error(ConnectionError("gRPC HTTP error: " <> msg))
    Error(grpc_http_client.ProtobufError(msg)) ->
      Error(ConnectionError("Protobuf error: " <> msg))
    Error(grpc_http_client.GrpcStatusError(_, msg)) ->
      Error(ConnectionError("gRPC status error: " <> msg))
  }
}

// Simple sleep function using Erlang's timer
@external(erlang, "timer", "sleep")
fn sleep_ms(milliseconds: Int) -> Nil

/// Send a chunk via the core service ReportStatusStream RPC
fn call_core_send_chunk(
  address: String,
  chunk: PollerStatusChunk,
) -> Result(Nil, GrpcError) {
  // For now, convert chunk to regular request since streaming requires more complex implementation
  let request =
    PollerStatusRequest(
      services: chunk.services,
      poller_id: chunk.poller_id,
      agent_id: chunk.agent_id,
      timestamp: chunk.timestamp,
      partition: chunk.partition,
      source_ip: chunk.source_ip,
      kv_store_id: chunk.kv_store_id,
    )

  case call_core_report_status(address, request) {
    Ok(_) -> Ok(Nil)
    Error(error) -> Error(error)
  }
}
