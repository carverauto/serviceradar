/// Real monitoring types based on monitoring.proto schema
/// These types match the actual ServiceRadar monitoring protobuf definitions
// Agent Service Types

/// Request to check service status on an agent
pub type StatusRequest {
  StatusRequest(
    service_name: String,
    // Type of service to check (process, port, dusk)
    service_type: String,
    // Type of service (process, port, grpc, etc)
    agent_id: String,
    // Agent ID for traceability
    poller_id: String,
    // Poller ID for traceability
    details: String,
    // Additional details (e.g., process name)
    port: Int,
    // Port number for port checks
  )
}

/// Response with service status from an agent
pub type StatusResponse {
  StatusResponse(
    available: Bool,
    message: BitArray,
    // bytes field as defined in proto
    service_name: String,
    service_type: String,
    response_time: Int,
    // int64 in nanoseconds
    agent_id: String,
    // Agent ID for traceability
    poller_id: String,
    // Poller ID for traceability
  )
}

/// Request for large result sets (sync/sweep services)
pub type ResultsRequest {
  ResultsRequest(
    service_name: String,
    // Name of the service to get results from
    service_type: String,
    // Type of service (grpc, etc)
    agent_id: String,
    // Agent ID for traceability
    poller_id: String,
    // Poller ID for traceability
    details: String,
    // Additional details
    last_sequence: String,
    // Last sequence received by poller
    completion_status: SweepCompletionStatus,
    // Completion status reported by poller
  )
}

/// Response with results data from an agent
pub type ResultsResponse {
  ResultsResponse(
    available: Bool,
    data: String,
    // Results data (converted from bytes)
    service_name: String,
    service_type: String,
    response_time: Int,
    // int64 in nanoseconds
    agent_id: String,
    poller_id: String,
    timestamp: Int,
    // When results were generated
    current_sequence: String,
    // Current sequence of this response
    has_new_data: Bool,
    // Whether data changed since last_sequence
    sweep_completion: SweepCompletionStatus,
    // Sweep completion status for coordination
  )
}

/// Chunked response for large result sets
pub type ResultsChunk {
  ResultsChunk(
    data: String,
    // Chunk of results data (converted from bytes)
    is_final: Bool,
    // Whether this is the last chunk
    chunk_index: Int,
    // Order of this chunk
    total_chunks: Int,
    // Total number of chunks
    current_sequence: String,
    // Current sequence of this chunk stream
    timestamp: Int,
    // When chunk was generated
  )
}

// Poller Service Types

/// Batch of service statuses to report to core
pub type PollerStatusRequest {
  PollerStatusRequest(
    services: List(ServiceStatus),
    poller_id: String,
    agent_id: String,
    // Agent ID for traceability
    timestamp: Int,
    // Batch timestamp
    partition: String,
    // Partition identifier (REQUIRED)
    source_ip: String,
    // Host IP where poller/agent is running (REQUIRED)
    kv_store_id: String,
    // KV store identifier this service is using
  )
}

/// Response from core service
pub type PollerStatusResponse {
  PollerStatusResponse(
    received: Bool,
    // Acknowledgment of receipt
  )
}

/// Individual service status
pub type ServiceStatus {
  ServiceStatus(
    service_name: String,
    available: Bool,
    message: BitArray,
    // bytes field as defined in proto
    service_type: String,
    response_time: Int,
    // Response time in nanoseconds
    agent_id: String,
    // Agent ID for traceability
    poller_id: String,
    // Poller ID for traceability
    partition: String,
    // Partition identifier
    source: String,
    // Source of the message: "status" or "results"
    kv_store_id: String,
    // KV store identifier this service is using
  )
}

/// Chunked batch for streaming large status reports
pub type PollerStatusChunk {
  PollerStatusChunk(
    services: List(ServiceStatus),
    // Chunk of service statuses
    poller_id: String,
    agent_id: String,
    timestamp: Int,
    partition: String,
    source_ip: String,
    is_final: Bool,
    // Whether this is the last chunk
    chunk_index: Int,
    // Order of this chunk
    total_chunks: Int,
    // Total number of chunks
    kv_store_id: String,
    // KV store identifier this service is using
  )
}

// Supporting Types

/// Sweep completion status for coordination
pub type SweepCompletionStatus {
  SweepCompletionStatus(
    status: SweepStatus,
    // Current completion status
    completion_time: Int,
    // Timestamp when sweep completed (if COMPLETED)
    target_sequence: String,
    // Sequence ID of the targets being swept
    total_targets: Int,
    // Total number of targets to sweep
    completed_targets: Int,
    // Number of targets completed so far
    error_message: String,
    // Error details if status is FAILED
  )
}

/// Sweep status enumeration
pub type SweepStatus {
  Unknown
  // Status not available
  NotStarted
  // Sweep has not been initiated
  InProgress
  // Sweep is currently running
  Completed
  // Sweep completed successfully
  Failed
  // Sweep failed or was interrupted
}

/// Helper function to convert SweepStatus to proto enum value
pub fn sweep_status_to_int(status: SweepStatus) -> Int {
  case status {
    Unknown -> 0
    NotStarted -> 1
    InProgress -> 2
    Completed -> 3
    Failed -> 4
  }
}

/// Helper function to convert proto enum value to SweepStatus
pub fn sweep_status_from_int(value: Int) -> SweepStatus {
  case value {
    0 -> Unknown
    1 -> NotStarted
    2 -> InProgress
    3 -> Completed
    4 -> Failed
    _ -> Unknown
    // Default for unknown values
  }
}
