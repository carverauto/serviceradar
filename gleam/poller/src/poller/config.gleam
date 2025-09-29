import gleam/dict.{type Dict}
import gleam/option.{type Option, None}
import gleam/result
import gleam/string
import poller/types.{
  type AgentConfig, type Check, type Config, Config,
}

pub type ConfigError {
  InvalidAddress(String)
  InvalidInterval(String)
  MissingRequired(String)
  InvalidSecurity(String)
}

pub fn validate_config(config: Config) -> Result(Config, ConfigError) {
  use _ <- result.try(validate_core_address(config.core_address))
  use _ <- result.try(validate_poll_interval(config.poll_interval))
  use _ <- result.try(validate_poller_id(config.poller_id))
  use _ <- result.try(validate_agents(config.agents))

  Ok(config)
}

fn validate_core_address(address: String) -> Result(Nil, ConfigError) {
  case string.is_empty(address) {
    True -> Error(MissingRequired("core_address"))
    False -> {
      case string.contains(address, ":") {
        True -> Ok(Nil)
        False -> Error(InvalidAddress("core_address must include port"))
      }
    }
  }
}

fn validate_poll_interval(interval: Int) -> Result(Nil, ConfigError) {
  case interval > 0 {
    True -> Ok(Nil)
    False -> Error(InvalidInterval("poll_interval must be positive"))
  }
}

fn validate_poller_id(poller_id: String) -> Result(Nil, ConfigError) {
  case string.is_empty(poller_id) {
    True -> Error(MissingRequired("poller_id"))
    False -> Ok(Nil)
  }
}

fn validate_agents(
  agents: Dict(String, AgentConfig),
) -> Result(Nil, ConfigError) {
  case dict.size(agents) == 0 {
    True -> Error(MissingRequired("at least one agent"))
    False -> {
      agents
      |> dict.to_list()
      |> validate_agent_list()
    }
  }
}

fn validate_agent_list(
  agents: List(#(String, AgentConfig)),
) -> Result(Nil, ConfigError) {
  case agents {
    [] -> Ok(Nil)
    [#(name, agent), ..rest] -> {
      use _ <- result.try(validate_agent(name, agent))
      validate_agent_list(rest)
    }
  }
}

fn validate_agent(name: String, agent: AgentConfig) -> Result(Nil, ConfigError) {
  use _ <- result.try(case string.is_empty(name) {
    True -> Error(MissingRequired("agent name"))
    False -> Ok(Nil)
  })

  use _ <- result.try(validate_core_address(agent.address))

  case agent.checks {
    [] -> Error(MissingRequired("agent must have at least one check"))
    checks -> validate_checks(checks)
  }
}

fn validate_checks(checks: List(Check)) -> Result(Nil, ConfigError) {
  case checks {
    [] -> Ok(Nil)
    [check, ..rest] -> {
      use _ <- result.try(validate_check(check))
      validate_checks(rest)
    }
  }
}

fn validate_check(check: Check) -> Result(Nil, ConfigError) {
  use _ <- result.try(case string.is_empty(check.name) {
    True -> Error(MissingRequired("check name"))
    False -> Ok(Nil)
  })

  use _ <- result.try(case string.is_empty(check.type_) {
    True -> Error(MissingRequired("check type"))
    False -> Ok(Nil)
  })

  use _ <- result.try(validate_poll_interval(check.interval))

  Ok(Nil)
}

pub fn create_default_config() -> Config {
  Config(
    agents: dict.new(),
    core_address: "localhost:9090",
    poll_interval: 30_000,
    poller_id: "default_poller",
    partition: "default",
    source_ip: "127.0.0.1",
    agent_id: "default_agent",
    kv_store_id: "default_kv_store",
    security: None,
  )
}

pub fn add_agent(config: Config, name: String, agent: AgentConfig) -> Config {
  Config(..config, agents: dict.insert(config.agents, name, agent))
}

pub fn get_agent(config: Config, name: String) -> Option(AgentConfig) {
  case dict.get(config.agents, name) {
    Ok(agent) -> option.Some(agent)
    Error(_) -> None
  }
}

pub fn remove_agent(config: Config, name: String) -> Config {
  Config(..config, agents: dict.delete(config.agents, name))
}

pub fn update_poll_interval(
  config: Config,
  new_interval: Int,
) -> Result(Config, ConfigError) {
  use _ <- result.try(validate_poll_interval(new_interval))
  Ok(Config(..config, poll_interval: new_interval))
}
