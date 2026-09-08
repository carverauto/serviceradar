defmodule ServiceRadarAgentGateway.TestSupport.MediaSessionTrackerTelemetry do
  @moduledoc false

  import ExUnit.Assertions

  def attach(handler_id, events, test_pid) do
    :telemetry.attach_many(handler_id, events, &__MODULE__.handle_event/4, test_pid)
  end

  def handle_event(event, measurements, metadata, test_pid) do
    send(test_pid, {:telemetry_event, event, measurements, metadata})
  end

  def assert_receive_telemetry(event, expected_metadata) do
    assert_receive {:telemetry_event, ^event, _measurements, metadata}

    Enum.each(expected_metadata, fn {key, value} ->
      assert Map.get(metadata, key) == value
    end)
  end
end
