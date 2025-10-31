/// HTTP-based gRPC client implementation
/// This module implements real gRPC calls over HTTP/2 using protobuf encoding
import gleam/http
import gleam/http/request.{type Request}
import gleam/httpc
import gleam/result
import gleam/string
import monitoring_codec
import monitoring_types.{type PollerStatusRequest, type PollerStatusResponse}

/// gRPC response wrapper
pub type GrpcResponse(a) {
  GrpcResponse(status: GrpcStatus, message: String, data: a)
}

/// gRPC status codes
pub type GrpcStatus {
  GrpcOk
  // 0
  Cancelled
  // 1
  Unknown
  // 2
  InvalidArgument
  // 3
  DeadlineExceeded
  // 4
  NotFound
  // 5
  AlreadyExists
  // 6
  PermissionDenied
  // 7
  Unauthenticated
  // 16
  ResourceExhausted
  // 8
  FailedPrecondition
  // 9
  Aborted
  // 10
  OutOfRange
  // 11
  Unimplemented
  // 12
  Internal
  // 13
  Unavailable
  // 14
  DataLoss
  // 15
}

/// Error type for gRPC calls
pub type GrpcError {
  HttpError(String)
  ProtobufError(String)
  GrpcStatusError(GrpcStatus, String)
}

/// Make a gRPC call to PollerService.ReportStatus
pub fn call_poller_service_report_status(
  endpoint: String,
  request: PollerStatusRequest,
) -> Result(PollerStatusResponse, GrpcError) {
  // Encode the request to protobuf
  let request_body = monitoring_codec.encode_poller_status_request(request)

  // Build the HTTP request
  use http_request <- result.try(
    build_grpc_request(
      endpoint,
      monitoring_codec.poller_service_report_status_path(),
      request_body,
    )
    |> result.map_error(HttpError),
  )

  // Make the HTTP call
  use http_response <- result.try(
    httpc.send_bits(http_request)
    |> result.map_error(fn(_) { HttpError("HTTP request failed") }),
  )

  // Parse the gRPC response
  case http_response.status {
    200 -> {
      // Decode the protobuf response
      use decoded_response <- result.try(
        monitoring_codec.decode_poller_status_response(http_response.body)
        |> result.map_error(ProtobufError),
      )

      Ok(decoded_response)
    }
    status -> Error(HttpError("HTTP " <> string.inspect(status)))
  }
}

/// Build a gRPC HTTP request
fn build_grpc_request(
  endpoint: String,
  method_path: String,
  body: BitArray,
) -> Result(Request(BitArray), String) {
  // Parse endpoint (e.g., "localhost:9090" -> "http://localhost:9090")
  let base_url = case string.contains(endpoint, "://") {
    True -> endpoint
    False -> "http://" <> endpoint
  }

  // Build the URL
  let url = base_url <> method_path

  // Create the request
  use request <- result.try(
    request.to(url)
    |> result.map_error(fn(_) { "Invalid URL: " <> url }),
  )

  // Set gRPC headers
  let grpc_request =
    request
    |> request.set_method(http.Post)
    |> request.set_body(body)
    |> request.set_header("content-type", monitoring_codec.grpc_content_type())
    |> request.set_header("te", "trailers")
    |> request.set_header("grpc-accept-encoding", "identity")

  Ok(grpc_request)
}

