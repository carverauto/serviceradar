/// Protobuf encoding and decoding for monitoring types using protozoa
/// This module provides conversion between our Gleam types and protobuf wire format
import gleam/bit_array
import gleam/list
import gleam/result
import monitoring_types.{
  type PollerStatusRequest, type PollerStatusResponse, type ServiceStatus,
  PollerStatusRequest, PollerStatusResponse, ServiceStatus,
}
import protozoa/decode
import protozoa/encode

// Field numbers from monitoring.proto

// PollerStatusRequest field numbers
const poller_status_request_services = 1

const poller_status_request_poller_id = 2

const poller_status_request_agent_id = 3

const poller_status_request_timestamp = 4

const poller_status_request_partition = 5

const poller_status_request_source_ip = 6

const poller_status_request_kv_store_id = 7

// PollerStatusResponse field numbers
const poller_status_response_received = 1

// ServiceStatus field numbers
const service_status_service_name = 1

const service_status_available = 2

const service_status_message = 3

const service_status_service_type = 4

const service_status_response_time = 5

const service_status_agent_id = 6

const service_status_poller_id = 7

const service_status_partition = 8

const service_status_source = 9

const service_status_kv_store_id = 10

/// Encode PollerStatusRequest to protobuf bytes
pub fn encode_poller_status_request(request: PollerStatusRequest) -> BitArray {
  let service_fields = list.map(request.services, encode_service_status_message)
  let repeated_services =
    list.map(service_fields, fn(msg) {
      encode.message_field(poller_status_request_services, msg)
    })

  encode.message([
    bit_array.concat(repeated_services),
    encode.string_field(poller_status_request_poller_id, request.poller_id),
    encode.string_field(poller_status_request_agent_id, request.agent_id),
    encode.int64_field(poller_status_request_timestamp, request.timestamp),
    encode.string_field(poller_status_request_partition, request.partition),
    encode.string_field(poller_status_request_source_ip, request.source_ip),
    encode.string_field(poller_status_request_kv_store_id, request.kv_store_id),
  ])
}

/// Encode ServiceStatus to protobuf message (for repeated fields)
fn encode_service_status_message(status: ServiceStatus) -> BitArray {
  encode.message([
    encode.string_field(service_status_service_name, status.service_name),
    encode.bool_field(service_status_available, status.available),
    encode.bytes(service_status_message, status.message),
    encode.string_field(service_status_service_type, status.service_type),
    encode.int64_field(service_status_response_time, status.response_time),
    encode.string_field(service_status_agent_id, status.agent_id),
    encode.string_field(service_status_poller_id, status.poller_id),
    encode.string_field(service_status_partition, status.partition),
    encode.string_field(service_status_source, status.source),
    encode.string_field(service_status_kv_store_id, status.kv_store_id),
  ])
}

/// Decode PollerStatusResponse from protobuf bytes
pub fn decode_poller_status_response(
  data: BitArray,
) -> Result(PollerStatusResponse, String) {
  let decoder = decode.bool(poller_status_response_received)

  case decode.run(data, decoder) {
    Ok(received) -> Ok(PollerStatusResponse(received: received))
    Error(_) -> Ok(PollerStatusResponse(received: False))
    // Default to false if decode fails
  }
}

/// Create a gRPC content-type header value
pub fn grpc_content_type() -> String {
  "application/grpc+proto"
}

/// Create gRPC method path for PollerService.ReportStatus
pub fn poller_service_report_status_path() -> String {
  "/monitoring.PollerService/ReportStatus"
}
