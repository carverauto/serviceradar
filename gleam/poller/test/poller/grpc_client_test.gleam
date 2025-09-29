import gleam/option.{None, Some}
import gleeunit/should
import poller/grpc_client.{
  StatusRequest, connect_channel, create_channel, get_status,
  service_check_to_status_request, status_response_to_service_status,
}
import poller/types.{Check}

pub fn create_channel_test() {
  case create_channel("localhost:8080") {
    Ok(channel) -> {
      channel.address
      |> should.equal("localhost:8080")

      channel.connected
      |> should.be_false()
    }
    Error(_) -> should.fail()
  }
}

pub fn create_channel_empty_address_test() {
  case create_channel("") {
    Ok(_) -> should.fail()
    Error(_) -> True |> should.be_true()
  }
}

pub fn connect_channel_test() {
  case create_channel("localhost:8080") {
    Ok(channel) -> {
      case connect_channel(channel) {
        Ok(connected_channel) -> {
          connected_channel.connected
          |> should.be_true()
        }
        Error(_) -> should.fail()
      }
    }
    Error(_) -> should.fail()
  }
}

pub fn connect_channel_failure_test() {
  case create_channel("fail-connection") {
    Ok(channel) -> {
      case connect_channel(channel) {
        Ok(_) -> should.fail()
        Error(_) -> True |> should.be_true()
      }
    }
    Error(_) -> should.fail()
  }
}

pub fn get_status_test() {
  case create_channel("localhost:8080") {
    Ok(channel) -> {
      case connect_channel(channel) {
        Ok(connected_channel) -> {
          let request =
            StatusRequest(
              service_name: "test_service",
              service_type: "http",
              agent_id: "test_agent",
              poller_id: "test_poller",
              details: Some("GET /health"),
              port: None,
            )

          case get_status(connected_channel, request) {
            Ok(response) -> {
              response.service_name
              |> should.equal("test_service")

              response.available
              |> should.be_true()

              response.agent_id
              |> should.equal("test_agent")
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

pub fn get_status_disconnected_test() {
  case create_channel("localhost:8080") {
    Ok(channel) -> {
      // Don't connect the channel
      let request =
        StatusRequest(
          service_name: "test_service",
          service_type: "http",
          agent_id: "test_agent",
          poller_id: "test_poller",
          details: None,
          port: None,
        )

      case get_status(channel, request) {
        Ok(_) -> should.fail()
        Error(_) -> True |> should.be_true()
      }
    }
    Error(_) -> should.fail()
  }
}

pub fn service_check_conversion_test() {
  let check =
    Check(
      name: "database_check",
      type_: "postgres",
      agent_id: "db_agent",
      poller_id: "test_poller",
      details: Some("SELECT 1"),
      interval: 60_000,
    )

  let request = service_check_to_status_request(check)

  request.service_name
  |> should.equal("database_check")

  request.service_type
  |> should.equal("postgres")

  request.agent_id
  |> should.equal("db_agent")

  request.poller_id
  |> should.equal("test_poller")

  request.details
  |> should.equal(Some("SELECT 1"))
}

pub fn status_response_conversion_test() {
  let response =
    grpc_client.StatusResponse(
      available: True,
      message: "Service healthy",
      service_name: "web_service",
      service_type: "http",
      response_time: 100_000_000,
      // 100ms
      agent_id: "web_agent",
      poller_id: "test_poller",
      timestamp: 1_640_000_000,
    )

  let service_status = status_response_to_service_status(response)

  service_status.service_name
  |> should.equal("web_service")

  service_status.available
  |> should.be_true()

  service_status.response_time
  |> should.equal(100_000_000)

  service_status.timestamp
  |> should.equal(1_640_000_000)
}
