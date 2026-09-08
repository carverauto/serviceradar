defmodule ServiceRadarAgentGateway.StatusBufferTest do
  use ExUnit.Case, async: false

  alias ServiceRadarAgentGateway.Config
  alias ServiceRadarAgentGateway.StatusBuffer

  setup do
    previous_config =
      try do
        {:ok, Config.get()}
      rescue
        ArgumentError -> :missing
      end

    Config.setup(gateway_id: "gateway-test", domain: "test", capabilities: [])
    on_exit(fn -> restore_config(previous_config) end)
  end

  test "overflow reports the evicted entry and retains the incoming entry" do
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

    old_status = %{
      gateway_id: "gateway-old",
      partition: "partition-old",
      source: "results",
      service_type: "sync",
      message: "old"
    }

    new_status = %{
      gateway_id: "gateway-new",
      partition: "partition-new",
      source: "status",
      service_type: "agent",
      message: "new-and-larger"
    }

    assert :ok = GenServer.call(buffer, {:enqueue, old_status})
    assert :ok = GenServer.call(buffer, {:enqueue, new_status})

    assert_receive {:telemetry, [:serviceradar, :agent_gateway, :results, :buffer, :dropped],
                    %{count: 1, bytes: dropped_bytes}, metadata}

    assert dropped_bytes == :erlang.external_size(old_status)
    assert metadata.reason == :overflow
    assert metadata.gateway_id == "gateway-old"
    assert metadata.partition == "partition-old"
    assert metadata.source == "results"
    assert metadata.service_type == "sync"
    assert 1 == GenServer.call(buffer, :size)

    assert %{queue: queue, retained_bytes: retained_bytes} = :sys.get_state(buffer)
    assert :queue.to_list(queue) == [new_status]
    assert retained_bytes == :erlang.external_size(new_status)
  end

  defp restore_config({:ok, config}) do
    Config.setup(
      gateway_id: config.gateway_id,
      domain: config.domain,
      capabilities: config.capabilities
    )
  end

  defp restore_config(:missing), do: :persistent_term.erase(Config)
end
