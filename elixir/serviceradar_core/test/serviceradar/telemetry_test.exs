defmodule ServiceRadar.TelemetryTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Telemetry

  setup do
    # Detach any existing handlers to avoid conflicts (ignore if not found)
    _ = :telemetry.detach("test-handler")

    # Clean up handlers after each test
    on_exit(fn ->
      _ = :telemetry.detach("test-handler")
    end)

    :ok
  end

  describe "emit_cluster_event/3" do
    test "emits cluster events with enriched metadata" do
      test_pid = self()

      :telemetry.attach(
        "test-handler",
        [:serviceradar, :cluster, :node_connected],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:event, event, measurements, metadata})
        end,
        nil
      )

      Telemetry.emit_cluster_event(:node_connected, %{target_node: :test@localhost}, %{
        latency: 100
      })

      assert_receive {:event, [:serviceradar, :cluster, :node_connected], measurements, metadata}
      assert measurements == %{latency: 100}
      assert metadata.target_node == :test@localhost
      assert metadata.node == node()
      assert is_integer(metadata.timestamp)
    end
  end

  describe "emit_gateway_event/3" do
    test "emits gateway events" do
      test_pid = self()

      :telemetry.attach(
        "test-handler",
        [:serviceradar, :gateway, :registered],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:event, event, measurements, metadata})
        end,
        nil
      )

      Telemetry.emit_gateway_event(
        :registered,
        %{partition_id: "p1", gateway_id: "gateway-001"},
        %{}
      )

      assert_receive {:event, [:serviceradar, :gateway, :registered], _, metadata}
      assert metadata.partition_id == "p1"
      assert metadata.gateway_id == "gateway-001"
    end
  end

  describe "emit_agent_event/3" do
    test "emits agent events" do
      test_pid = self()

      :telemetry.attach(
        "test-handler",
        [:serviceradar, :agent, :connected],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:event, event, measurements, metadata})
        end,
        nil
      )

      Telemetry.emit_agent_event(:connected, %{agent_id: "agent-001"}, %{})

      assert_receive {:event, [:serviceradar, :agent, :connected], _, metadata}
      assert metadata.agent_id == "agent-001"
    end
  end

  describe "emit_registry_event/3" do
    test "emits registry events" do
      test_pid = self()

      :telemetry.attach(
        "test-handler",
        [:serviceradar, :registry, :lookup_hit],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:event, event, measurements, metadata})
        end,
        nil
      )

      Telemetry.emit_registry_event(:lookup_hit, %{registry: :gateway}, %{duration: 50})

      assert_receive {:event, [:serviceradar, :registry, :lookup_hit], measurements, metadata}
      assert measurements.duration == 50
      assert metadata.registry == :gateway
    end
  end

  describe "emit_camera_relay_session_event/3" do
    test "emits camera relay lifecycle events with enriched metadata" do
      test_pid = self()

      :telemetry.attach(
        "test-handler",
        [:serviceradar, :camera_relay, :session, :closed],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:event, event, measurements, metadata})
        end,
        nil
      )

      Telemetry.emit_camera_relay_session_event(
        :closed,
        %{
          relay_boundary: "core_elx",
          relay_session_id: "relay-1",
          termination_kind: "viewer_idle"
        },
        %{viewer_count: 0, sent_bytes: 1024}
      )

      assert_receive {:event, [:serviceradar, :camera_relay, :session, :closed], measurements,
                      metadata}

      assert measurements.viewer_count == 0
      assert measurements.sent_bytes == 1024
      assert metadata.relay_boundary == "core_elx"
      assert metadata.relay_session_id == "relay-1"
      assert metadata.termination_kind == "viewer_idle"
      assert metadata.node == node()
      assert is_integer(metadata.timestamp)
    end
  end

  describe "emit_camera_relay_analysis_event/3" do
    test "emits camera relay analysis events with enriched metadata" do
      test_pid = self()

      :telemetry.attach(
        "test-handler",
        [:serviceradar, :camera_relay, :analysis, :sample_dropped],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:event, event, measurements, metadata})
        end,
        nil
      )

      Telemetry.emit_camera_relay_analysis_event(
        :sample_dropped,
        %{
          relay_boundary: "core_elx",
          relay_session_id: "relay-1",
          branch_id: "branch-1",
          reason: "backpressure"
        },
        %{payload_bytes: 1024, queue_length: 9}
      )

      assert_receive {:event, [:serviceradar, :camera_relay, :analysis, :sample_dropped],
                      measurements, metadata}

      assert measurements.payload_bytes == 1024
      assert measurements.queue_length == 9
      assert metadata.relay_boundary == "core_elx"
      assert metadata.relay_session_id == "relay-1"
      assert metadata.branch_id == "branch-1"
      assert metadata.reason == "backpressure"
      assert metadata.node == node()
      assert is_integer(metadata.timestamp)
    end

    test "emits analysis dispatch events" do
      test_pid = self()

      :telemetry.attach(
        "test-handler",
        [:serviceradar, :camera_relay, :analysis, :dispatch_failed],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:event, event, measurements, metadata})
        end,
        nil
      )

      Telemetry.emit_camera_relay_analysis_event(
        :dispatch_failed,
        %{
          relay_boundary: "core_elx",
          relay_session_id: "relay-1",
          branch_id: "branch-1",
          worker_id: "worker-1",
          reason: "http_status_503"
        },
        %{inflight_count: 1, sequence: 7}
      )

      assert_receive {:event, [:serviceradar, :camera_relay, :analysis, :dispatch_failed],
                      measurements, metadata}

      assert measurements.inflight_count == 1
      assert measurements.sequence == 7
      assert metadata.worker_id == "worker-1"
      assert metadata.reason == "http_status_503"
    end
  end

  describe "span/3" do
    test "emits start and stop events around function execution" do
      test_pid = self()

      :telemetry.attach_many(
        "test-handler",
        [
          [:serviceradar, :test, :operation, :start],
          [:serviceradar, :test, :operation, :stop]
        ],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:event, event, measurements, metadata})
        end,
        nil
      )

      result =
        Telemetry.span([:serviceradar, :test, :operation], %{test: true}, fn ->
          Process.sleep(10)
          :test_result
        end)

      assert result == :test_result

      assert_receive {:event, [:serviceradar, :test, :operation, :start], _, start_metadata}
      assert start_metadata.test == true

      assert_receive {:event, [:serviceradar, :test, :operation, :stop], stop_measurements, _}
      assert stop_measurements.duration > 0
    end

    test "emits exception event on error" do
      test_pid = self()

      :telemetry.attach(
        "test-handler",
        [:serviceradar, :test, :error, :exception],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:event, event, measurements, metadata})
        end,
        nil
      )

      assert_raise RuntimeError, fn ->
        Telemetry.span([:serviceradar, :test, :error], %{}, fn ->
          raise "test error"
        end)
      end

      assert_receive {:event, [:serviceradar, :test, :error, :exception], _, metadata}
      assert metadata.kind == :error
    end
  end

  describe "metrics/0" do
    test "returns list of metric definitions" do
      metrics = Telemetry.metrics()

      assert is_list(metrics)
      refute Enum.empty?(metrics)

      # Check for expected metrics - names are stored as atom lists
      metric_names = Enum.map(metrics, & &1.name)

      assert [:serviceradar, :cluster, :node_connected, :count] in metric_names
      assert [:serviceradar, :gateway, :registered, :count] in metric_names
      assert [:serviceradar, :agent, :connected, :count] in metric_names
      assert [:serviceradar, :registry, :lookup, :count] in metric_names
      assert [:serviceradar, :camera_relay, :session, :opened, :count] in metric_names
      assert [:serviceradar, :camera_relay, :session, :viewer_count] in metric_names
      assert [:serviceradar, :camera_relay, :analysis, :branch_opened, :count] in metric_names
      assert [:serviceradar, :camera_relay, :analysis, :branch_count] in metric_names

      assert [:serviceradar, :camera_relay, :analysis, :dispatch_succeeded, :count] in metric_names

      assert [:serviceradar, :camera_relay, :analysis, :dispatch_failed, :count] in metric_names

      assert [:serviceradar, :camera_relay, :analysis, :dispatch_timed_out, :count] in metric_names

      assert [:serviceradar, :camera_relay, :analysis, :dispatch_dropped, :count] in metric_names
    end
  end

  describe "camera_relay_metrics/0" do
    test "returns the camera relay metric subset without unrelated metrics" do
      metrics = Telemetry.camera_relay_metrics()

      metric_names = Enum.map(metrics, & &1.name)

      assert [:serviceradar, :camera_relay, :session, :opened, :count] in metric_names
      assert [:serviceradar, :camera_relay, :session, :closing, :count] in metric_names
      assert [:serviceradar, :camera_relay, :session, :closed, :count] in metric_names
      assert [:serviceradar, :camera_relay, :session, :failed, :count] in metric_names
      assert [:serviceradar, :camera_relay, :session, :viewer_count] in metric_names
      assert [:serviceradar, :camera_relay, :analysis, :branch_opened, :count] in metric_names
      assert [:serviceradar, :camera_relay, :analysis, :branch_closed, :count] in metric_names
      assert [:serviceradar, :camera_relay, :analysis, :sample_emitted, :count] in metric_names
      assert [:serviceradar, :camera_relay, :analysis, :sample_dropped, :count] in metric_names
      assert [:serviceradar, :camera_relay, :analysis, :limit_rejected, :count] in metric_names

      assert [:serviceradar, :camera_relay, :analysis, :dispatch_succeeded, :count] in metric_names

      assert [:serviceradar, :camera_relay, :analysis, :dispatch_failed, :count] in metric_names

      assert [:serviceradar, :camera_relay, :analysis, :dispatch_timed_out, :count] in metric_names

      assert [:serviceradar, :camera_relay, :analysis, :dispatch_dropped, :count] in metric_names
      assert [:serviceradar, :camera_relay, :analysis, :branch_count] in metric_names
      refute [:serviceradar, :cluster, :node_connected, :count] in metric_names
    end
  end

  describe "periodic_measurements/0" do
    test "returns list of measurement functions" do
      measurements = Telemetry.periodic_measurements()

      assert is_list(measurements)
      refute Enum.empty?(measurements)

      # Each should be a tuple of {module, function, args}
      Enum.each(measurements, fn {module, function, args} ->
        assert is_atom(module)
        assert is_atom(function)
        assert is_list(args)
      end)
    end
  end

  describe "attach_default_handlers/0" do
    test "attaches handlers without error" do
      assert :ok = Telemetry.attach_default_handlers()

      # Clean up
      Telemetry.detach_default_handlers()
    end
  end

  describe "measure_cluster_size/0" do
    test "emits cluster nodes measurement" do
      test_pid = self()

      :telemetry.attach(
        "test-handler",
        [:serviceradar, :cluster, :nodes],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:event, event, measurements, metadata})
        end,
        nil
      )

      Telemetry.measure_cluster_size()

      assert_receive {:event, [:serviceradar, :cluster, :nodes], measurements, metadata}
      # At least the current node
      assert measurements.count >= 1
      assert is_list(metadata.nodes)
    end
  end
end
