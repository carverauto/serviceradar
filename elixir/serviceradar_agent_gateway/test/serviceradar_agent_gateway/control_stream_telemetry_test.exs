defmodule ServiceRadarAgentGateway.ControlStreamTelemetryTest do
  use ExUnit.Case, async: false

  alias ServiceRadarAgentGateway.Config
  alias ServiceRadarAgentGateway.ControlStreamTelemetry

  @moduletag :requires_app

  setup do
    handler_id = "control-stream-telemetry-#{System.unique_integer([:positive])}"
    parent = self()

    :ok =
      :telemetry.attach_many(
        handler_id,
        [
          [:serviceradar, :agent_gateway, :control_stream, :established],
          [:serviceradar, :agent_gateway, :control_stream, :closed],
          [:serviceradar, :agent_gateway, :control_stream, :active]
        ],
        fn event, measurements, metadata, test_pid ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        parent
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end

  test "tracks control stream churn and active sessions" do
    session =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    gateway_id = Config.gateway_id()

    ControlStreamTelemetry.connected(session, %{gateway_id: gateway_id})

    assert_receive {
      :telemetry,
      [:serviceradar, :agent_gateway, :control_stream, :established],
      %{count: 1},
      %{gateway_id: ^gateway_id}
    }

    assert_receive {
      :telemetry,
      [:serviceradar, :agent_gateway, :control_stream, :active],
      %{count: active_sessions},
      %{gateway_id: ^gateway_id}
    }

    assert active_sessions >= 1

    send(session, :stop)

    assert_receive {
      :telemetry,
      [:serviceradar, :agent_gateway, :control_stream, :closed],
      %{count: 1},
      %{gateway_id: ^gateway_id}
    }
  end
end
