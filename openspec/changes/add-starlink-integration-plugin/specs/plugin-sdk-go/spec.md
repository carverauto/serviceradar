## ADDED Requirements

### Requirement: Unary gRPC Wrapper
The Go SDK SHALL provide a wrapper for the host `grpc_unary` function that sends a method
path, metadata and raw protobuf request bytes over `h2c` or TLS and returns the gRPC status,
message, headers, trailers and response bytes.

#### Scenario: Successful unary call
- **WHEN** a plugin with the `grpc_request` capability calls an allowed destination
- **THEN** the wrapper returns the response bytes and a zero gRPC status

#### Scenario: Non-OK gRPC status
- **WHEN** the server returns a non-OK gRPC status
- **THEN** the wrapper returns the status code and message as a typed error with trailers available

#### Scenario: Local dev host
- **WHEN** a plugin test runs against the native local host with a caller-supplied gRPC handler
- **THEN** unary calls are served by that handler without TinyGo

### Requirement: HTTP Response Envelope Mode
The Go SDK SHALL provide a named response-envelope mode that returns response headers
together with status and body, plus helpers for reading headers and `Retry-After`, while
leaving the default status-body mode unchanged.

#### Scenario: Rate-limited response
- **WHEN** a plugin using envelope mode receives HTTP 429 with `Retry-After`
- **THEN** the helper returns the retry delay

#### Scenario: Existing plugins unaffected
- **WHEN** a plugin does not select a response mode
- **THEN** it receives the same status-body response as before

### Requirement: Typed Credential Broker Grants
The Go SDK SHALL expose typed constants, builders and shared fixtures for the credential
broker grant and injection types the host accepts, including `oauth2_client_credentials`,
and the local dev host SHALL emulate bearer injection for such grants.

#### Scenario: Client-credentials grant in local tests
- **WHEN** a plugin test declares an `oauth2_client_credentials` grant and provides credential environment values
- **THEN** outbound requests in the local host carry an injected bearer header and the plugin never reads the client secret

### Requirement: Tagged SDK Release And Install Path
The Go SDK SHALL publish the gRPC, envelope and typed-grant surfaces in a tagged release
(`v2.2.0` or later), and its README SHALL document the `/v2` module path together with the
`GOPRIVATE`/`GONOSUMDB` settings needed to fetch it directly.

#### Scenario: Plugin pins a tag
- **WHEN** the Starlink plugin module is built
- **THEN** its `go.mod` requires a tagged SDK version and its committed `vendor/` matches it
