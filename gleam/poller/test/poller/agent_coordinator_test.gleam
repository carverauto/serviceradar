import gleam/option.{None}
import gleeunit/should
import poller/agent_coordinator.{
  connect_agent, create_agent_coordinator, disconnect_agent, execute_check,
  get_circuit_state, get_connection_state, get_failure_count,
  reset_circuit_breaker,
}
import poller/types.{
  AgentConfig, Check, Closed, Connected, Disconnected, Failed, Open,
}

pub fn create_agent_coordinator_test() {
  let config =
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
    )

  case create_agent_coordinator("test_agent", config) {
    Ok(state) -> {
      state.agent_name
      |> should.equal("test_agent")

      get_connection_state(state)
      |> should.equal(Disconnected)

      get_circuit_state(state)
      |> should.equal(Closed)

      get_failure_count(state)
      |> should.equal(0)
    }
    Error(_) -> should.fail()
  }
}

pub fn create_agent_coordinator_invalid_config_test() {
  let invalid_config = AgentConfig(address: "", checks: [], security: None)

  case create_agent_coordinator("test_agent", invalid_config) {
    Ok(_) -> should.fail()
    Error(_) -> True |> should.be_true()
  }
}

pub fn connect_agent_test() {
  let config =
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
    )

  case create_agent_coordinator("test_agent", config) {
    Ok(state) -> {
      case connect_agent(state) {
        Ok(connected_state) -> {
          get_connection_state(connected_state)
          |> should.equal(Connected)

          get_failure_count(connected_state)
          |> should.equal(0)
        }
        Error(_) -> should.fail()
      }
    }
    Error(_) -> should.fail()
  }
}

pub fn connect_agent_failure_test() {
  let config =
    AgentConfig(
      address: "fail",
      // This will trigger a simulated failure
      checks: [
        Check(
          name: "test",
          type_: "http",
          agent_id: "test_agent",
          poller_id: "test_poller",
          details: None,
          interval: 30_000,
        ),
      ],
      security: None,
    )

  case create_agent_coordinator("test_agent", config) {
    Ok(state) -> {
      case connect_agent(state) {
        Ok(failed_state) -> {
          get_connection_state(failed_state)
          |> should.equal(Failed)

          get_failure_count(failed_state)
          |> should.equal(1)
        }
        Error(_) -> should.fail()
      }
    }
    Error(_) -> should.fail()
  }
}

pub fn disconnect_agent_test() {
  let config =
    AgentConfig(
      address: "localhost:8080",
      checks: [
        Check(
          name: "test",
          type_: "http",
          agent_id: "test_agent",
          poller_id: "test_poller",
          details: None,
          interval: 30_000,
        ),
      ],
      security: None,
    )

  case create_agent_coordinator("test_agent", config) {
    Ok(state) -> {
      case connect_agent(state) {
        Ok(connected_state) -> {
          let disconnected_state = disconnect_agent(connected_state)

          get_connection_state(disconnected_state)
          |> should.equal(Disconnected)
        }
        Error(_) -> should.fail()
      }
    }
    Error(_) -> should.fail()
  }
}

pub fn execute_check_test() {
  let check =
    Check(
      name: "database_check",
      type_: "postgres",
      agent_id: "db_agent",
      poller_id: "test_poller",
      details: None,
      interval: 60_000,
    )

  let config =
    AgentConfig(address: "localhost:8080", checks: [check], security: None)

  case create_agent_coordinator("db_agent", config) {
    Ok(state) -> {
      case connect_agent(state) {
        Ok(connected_state) -> {
          case execute_check(connected_state, check) {
            Ok(status) -> {
              status.service_name
              |> should.equal("database_check")

              status.available
              |> should.be_true()

              status.agent_id
              |> should.equal("db_agent")
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

pub fn circuit_breaker_test() {
  let config =
    AgentConfig(
      address: "localhost:8080",
      checks: [
        Check(
          name: "test",
          type_: "http",
          agent_id: "test_agent",
          poller_id: "test_poller",
          details: None,
          interval: 30_000,
        ),
      ],
      security: None,
    )

  case create_agent_coordinator("test_agent", config) {
    Ok(state) -> {
      let reset_state = reset_circuit_breaker(state)

      get_circuit_state(reset_state)
      |> should.equal(Closed)

      get_failure_count(reset_state)
      |> should.equal(0)
    }
    Error(_) -> should.fail()
  }
}
