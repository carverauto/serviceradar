import gleam/dict
import gleam/option.{None, Some}
import gleeunit/should
import poller/types.{
  AgentConfig, Check, Config, Enabled, SecurityConfig, TlsConfig,
}

pub fn valid_config_test() {
  let config =
    Config(
      agents: dict.new()
        |> dict.insert(
          "agent1",
          AgentConfig(
            address: "localhost:8080",
            checks: [
              Check(
                name: "health_check",
                type_: "http",
                agent_id: "agent1",
                poller_id: "poller1",
                details: Some("GET /health"),
                interval: 30_000,
              ),
            ],
            security: None,
          ),
        ),
      core_address: "localhost:9090",
      poll_interval: 30_000,
      poller_id: "poller1",
      partition: "default",
      source_ip: "127.0.0.1",
      agent_id: "test_agent",
      kv_store_id: "test_kv_store",
      security: None,
    )

  config.core_address
  |> should.equal("localhost:9090")

  config.poll_interval
  |> should.equal(30_000)

  dict.size(config.agents)
  |> should.equal(1)
}

pub fn security_config_test() {
  let tls_config =
    TlsConfig(
      cert_file: "/path/to/cert.pem",
      key_file: "/path/to/key.pem",
      ca_file: "/path/to/ca.pem",
      server_name: "agent.example.com",
    )

  let security_config = SecurityConfig(tls: Some(tls_config), mode: Enabled)

  security_config.mode
  |> should.equal(Enabled)

  case security_config.tls {
    Some(tls) -> tls.server_name |> should.equal("agent.example.com")
    None -> should.fail()
  }
}

pub fn check_validation_test() {
  let check =
    Check(
      name: "database_check",
      type_: "postgres",
      agent_id: "db_agent",
      poller_id: "poller1",
      details: Some("SELECT 1"),
      interval: 60_000,
    )

  check.name
  |> should.equal("database_check")

  check.interval
  |> should.equal(60_000)
}
