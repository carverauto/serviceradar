import gleam/dict.{type Dict}
import gleam/option.{type Option}

pub type Config {
  Config(
    agents: Dict(String, AgentConfig),
    core_address: String,
    poll_interval: Int,
    poller_id: String,
    partition: String,
    source_ip: String,
    agent_id: String,
    kv_store_id: String,
    security: Option(SecurityConfig),
  )
}

pub type AgentConfig {
  AgentConfig(
    address: String,
    checks: List(Check),
    security: Option(SecurityConfig),
  )
}

pub type SecurityConfig {
  SecurityConfig(tls: Option(TlsConfig), mode: SecurityMode)
}

pub type TlsConfig {
  TlsConfig(
    cert_file: String,
    key_file: String,
    ca_file: String,
    server_name: String,
  )
}

pub type SecurityMode {
  Disabled
  Enabled
  Strict
}

pub type Check {
  Check(
    name: String,
    type_: String,
    agent_id: String,
    poller_id: String,
    details: Option(String),
    interval: Int,
  )
}

pub type ServiceStatus {
  ServiceStatus(
    service_name: String,
    available: Bool,
    message: String,
    service_type: String,
    response_time: Int,
    agent_id: String,
    poller_id: String,
    timestamp: Int,
  )
}

pub type CircuitState {
  Closed
  Open
  HalfOpen
}

pub type GrpcError {
  TimeoutError
  ConnectionError(String)
  AuthenticationError(String)
  InvalidRequest(String)
  ServerError(String)
}

pub type PollResult =
  Result(ServiceStatus, GrpcError)

pub type AgentConnectionState {
  Connected
  Disconnected
  Reconnecting
  Failed
}
