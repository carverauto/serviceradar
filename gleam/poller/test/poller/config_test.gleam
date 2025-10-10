import gleam/dict
import gleam/option.{None, Some}
import gleeunit/should
import poller/config.{
  InvalidAddress, InvalidInterval, MissingRequired, add_agent,
  create_default_config, get_agent, remove_agent, update_poll_interval,
  validate_config,
}
import poller/types.{AgentConfig, Check, Config}

pub fn create_default_config_test() {
  let config = create_default_config()

  config.core_address
  |> should.equal("localhost:9090")

  config.poll_interval
  |> should.equal(30_000)

  config.poller_id
  |> should.equal("default_poller")

  dict.size(config.agents)
  |> should.equal(0)
}

pub fn validate_valid_config_test() {
  let config =
    create_default_config()
    |> add_agent(
      "test_agent",
      AgentConfig(
        address: "localhost:8080",
        checks: [
          Check(
            name: "health",
            type_: "http",
            agent_id: "test_agent",
            poller_id: "default_poller",
            details: Some("GET /health"),
            interval: 30_000,
          ),
        ],
        security: None,
      ),
    )

  validate_config(config)
  |> should.be_ok()
}

pub fn validate_missing_core_address_test() {
  let config = Config(..create_default_config(), core_address: "")

  validate_config(config)
  |> should.be_error()
  |> should.equal(MissingRequired("core_address"))
}

pub fn validate_invalid_core_address_test() {
  let config = Config(..create_default_config(), core_address: "localhost")

  validate_config(config)
  |> should.be_error()
  |> should.equal(InvalidAddress("core_address must include port"))
}

pub fn validate_invalid_poll_interval_test() {
  let config = Config(..create_default_config(), poll_interval: 0)

  validate_config(config)
  |> should.be_error()
  |> should.equal(InvalidInterval("poll_interval must be positive"))
}

pub fn validate_missing_poller_id_test() {
  let config = Config(..create_default_config(), poller_id: "")

  validate_config(config)
  |> should.be_error()
  |> should.equal(MissingRequired("poller_id"))
}

pub fn validate_no_agents_test() {
  let config = create_default_config()

  validate_config(config)
  |> should.be_error()
  |> should.equal(MissingRequired("at least one agent"))
}

pub fn add_and_get_agent_test() {
  let agent =
    AgentConfig(
      address: "localhost:8080",
      checks: [
        Check(
          name: "ping",
          type_: "icmp",
          agent_id: "ping_agent",
          poller_id: "test_poller",
          details: None,
          interval: 5000,
        ),
      ],
      security: None,
    )

  let config =
    create_default_config()
    |> add_agent("ping_agent", agent)

  case get_agent(config, "ping_agent") {
    Some(retrieved_agent) -> {
      retrieved_agent.address
      |> should.equal("localhost:8080")
    }
    None -> should.fail()
  }

  get_agent(config, "nonexistent")
  |> should.equal(None)
}

pub fn remove_agent_test() {
  let agent = AgentConfig(address: "localhost:8080", checks: [], security: None)

  let config =
    create_default_config()
    |> add_agent("test_agent", agent)
    |> remove_agent("test_agent")

  dict.size(config.agents)
  |> should.equal(0)

  get_agent(config, "test_agent")
  |> should.equal(None)
}

pub fn update_poll_interval_test() {
  let config = create_default_config()

  case update_poll_interval(config, 60_000) {
    Ok(updated_config) -> {
      updated_config.poll_interval
      |> should.equal(60_000)
    }
    Error(_) -> should.fail()
  }

  update_poll_interval(config, 0)
  |> should.be_error()
  |> should.equal(InvalidInterval("poll_interval must be positive"))
}
