import gleam/option.{None}
import gleeunit/should
import poller/config
import poller/simple_supervisor.{
  create_supervisor, get_config, is_running, start_supervisor, stop_supervisor,
}
import poller/types.{AgentConfig, Check}

pub fn create_supervisor_test() {
  let config =
    config.create_default_config()
    |> config.add_agent(
      "test_agent",
      AgentConfig(
        address: "localhost:8080",
        checks: [
          Check(
            name: "health",
            type_: "http",
            agent_id: "test_agent",
            poller_id: "test_poller",
            details: None,
            interval: 30_000,
          ),
        ],
        security: None,
      ),
    )

  case create_supervisor(config) {
    Ok(supervisor_state) -> {
      is_running(supervisor_state)
      |> should.be_false()

      get_config(supervisor_state).poller_id
      |> should.equal("default_poller")
    }
    Error(_) -> should.fail()
  }
}

pub fn start_stop_supervisor_test() {
  let config =
    config.create_default_config()
    |> config.add_agent(
      "test_agent",
      AgentConfig(
        address: "localhost:8080",
        checks: [
          Check(
            name: "ping",
            type_: "icmp",
            agent_id: "test_agent",
            poller_id: "test_poller",
            details: None,
            interval: 5000,
          ),
        ],
        security: None,
      ),
    )

  case create_supervisor(config) {
    Ok(supervisor_state) -> {
      // Test starting
      case start_supervisor(supervisor_state) {
        Ok(started_state) -> {
          is_running(started_state)
          |> should.be_true()

          // Test stopping
          case stop_supervisor(started_state) {
            Ok(stopped_state) -> {
              is_running(stopped_state)
              |> should.be_false()
            }
            Error(_) -> should.fail()
          }
        }
        Error(_) -> should.fail()
      }
    }
    Error(_) -> should.fail()
  }
}

pub fn create_supervisor_invalid_config_test() {
  let invalid_config = config.create_default_config()
  // No agents added, should be invalid

  case create_supervisor(invalid_config) {
    Ok(_) -> should.fail()
    Error(_) -> True |> should.be_true()
  }
}
