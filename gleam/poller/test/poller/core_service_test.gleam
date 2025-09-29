import gleam/list
import gleam/string
import gleeunit/should
import monitoring_types.{PollerStatusResponse}
import poller/config
import poller/core_service.{
  CoreChannel, connect_core_channel, create_core_channel, report_status,
  report_status_stream,
}
import poller/types.{ServiceStatus}

pub fn create_core_channel_test() {
  case
    create_core_channel(
      "localhost:8080",
      "test_poller",
      "partition_1",
      "127.0.0.1",
    )
  {
    Ok(channel) -> {
      channel.address
      |> should.equal("localhost:8080")

      channel.connected
      |> should.be_false()

      channel.poller_id
      |> should.equal("test_poller")

      channel.partition
      |> should.equal("partition_1")

      channel.source_ip
      |> should.equal("127.0.0.1")
    }
    Error(_) -> should.fail()
  }
}

pub fn create_core_channel_empty_address_test() {
  case create_core_channel("", "test_poller", "partition_1", "127.0.0.1") {
    Ok(_) -> should.fail()
    Error(_) -> True |> should.be_true()
  }
}

pub fn connect_core_channel_test() {
  case
    create_core_channel(
      "localhost:8080",
      "test_poller",
      "partition_1",
      "127.0.0.1",
    )
  {
    Ok(channel) -> {
      case connect_core_channel(channel) {
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

pub fn connect_core_channel_invalid_address_test() {
  case
    create_core_channel(
      "invalid-address",
      "test_poller",
      "partition_1",
      "127.0.0.1",
    )
  {
    Ok(channel) -> {
      case connect_core_channel(channel) {
        Ok(_) -> should.fail()
        Error(_) -> True |> should.be_true()
      }
    }
    Error(_) -> should.fail()
  }
}

pub fn report_status_test() {
  case
    create_core_channel(
      "localhost:8080",
      "test_poller",
      "partition_1",
      "127.0.0.1",
    )
  {
    Ok(channel) -> {
      case connect_core_channel(channel) {
        Ok(connected_channel) -> {
          let services = [
            ServiceStatus(
              service_name: "test_service",
              available: True,
              message: "Service is healthy",
              service_type: "http",
              response_time: 100_000_000,
              agent_id: "test_agent",
              poller_id: "test_poller",
              timestamp: 1_640_000_000,
            ),
          ]

          let test_config = config.create_default_config()

          case report_status(connected_channel, services, test_config) {
            Ok(response) -> {
              response.received
              |> should.be_true()
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

pub fn report_status_disconnected_test() {
  case
    create_core_channel(
      "localhost:8080",
      "test_poller",
      "partition_1",
      "127.0.0.1",
    )
  {
    Ok(channel) -> {
      // Don't connect the channel
      let services = [
        ServiceStatus(
          service_name: "test_service",
          available: True,
          message: "Service is healthy",
          service_type: "http",
          response_time: 100_000_000,
          agent_id: "test_agent",
          poller_id: "test_poller",
          timestamp: 1_640_000_000,
        ),
      ]

      let test_config = config.create_default_config()

      case report_status(channel, services, test_config) {
        Ok(_) -> should.fail()
        Error(_) -> True |> should.be_true()
      }
    }
    Error(_) -> should.fail()
  }
}

pub fn report_status_stream_test() {
  case
    create_core_channel(
      "localhost:8080",
      "test_poller",
      "partition_1",
      "127.0.0.1",
    )
  {
    Ok(channel) -> {
      case connect_core_channel(channel) {
        Ok(connected_channel) -> {
          // Create a list of 5 services to test chunking
          let services =
            list.range(1, 5)
            |> list.map(fn(i) {
              ServiceStatus(
                service_name: "test_service_" <> string.inspect(i),
                available: True,
                message: "Service is healthy",
                service_type: "http",
                response_time: 100_000_000,
                agent_id: "test_agent",
                poller_id: "test_poller",
                timestamp: 1_640_000_000,
              )
            })

          let test_config = config.create_default_config()

          case
            report_status_stream(connected_channel, services, 2, test_config)
          {
            Ok(response) -> {
              response.received
              |> should.be_true()
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

pub fn report_status_stream_empty_list_test() {
  case
    create_core_channel(
      "localhost:8080",
      "test_poller",
      "partition_1",
      "127.0.0.1",
    )
  {
    Ok(channel) -> {
      case connect_core_channel(channel) {
        Ok(connected_channel) -> {
          let test_config = config.create_default_config()

          case report_status_stream(connected_channel, [], 10, test_config) {
            Ok(response) -> {
              response.received
              |> should.be_true()
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
