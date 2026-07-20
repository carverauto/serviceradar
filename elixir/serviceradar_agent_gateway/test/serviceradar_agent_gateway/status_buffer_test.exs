defmodule ServiceRadarAgentGateway.StatusBufferTest do
  use ExUnit.Case, async: false

  alias ServiceRadarAgentGateway.StatusBuffer

  test "emits a dropped-count telemetry event when the bounded queue overflows" do
    handler_id = "status-buffer-overflow-#{System.unique_integer([:positive])}"
    parent = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:serviceradar, :agent_gateway, :results, :buffer, :dropped],
        fn event, measurements, metadata, test_pid ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        parent
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    {:ok, buffer} = StatusBuffer.start_link(name: nil, max_entries: 1, flush_interval_ms: 60_000)
    status = %{gateway_id: "gateway-1", partition: "partition-1"}

    assert :ok = GenServer.call(buffer, {:enqueue, status})
    assert :ok = GenServer.call(buffer, {:enqueue, status})

    assert_receive {:telemetry, [:serviceradar, :agent_gateway, :results, :buffer, :dropped], %{count: 1}, metadata}
    assert metadata.reason == :overflow
    assert metadata.gateway_id == "gateway-1"
    assert metadata.partition == "partition-1"
    assert 1 == GenServer.call(buffer, :size)
  end
end
