defmodule ServiceRadar.EventWriter.ConfigTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.EventWriter.Config

  describe "enabled?/0" do
    test "returns false by default" do
      # Clear any existing env var
      System.delete_env("EVENT_WRITER_ENABLED")

      refute Config.enabled?()
    end

    test "returns true when EVENT_WRITER_ENABLED is 'true'" do
      System.put_env("EVENT_WRITER_ENABLED", "true")
      on_exit(fn -> System.delete_env("EVENT_WRITER_ENABLED") end)

      assert Config.enabled?()
    end

    test "returns true when EVENT_WRITER_ENABLED is '1'" do
      System.put_env("EVENT_WRITER_ENABLED", "1")
      on_exit(fn -> System.delete_env("EVENT_WRITER_ENABLED") end)

      assert Config.enabled?()
    end

    test "returns true when EVENT_WRITER_ENABLED is 'yes'" do
      System.put_env("EVENT_WRITER_ENABLED", "yes")
      on_exit(fn -> System.delete_env("EVENT_WRITER_ENABLED") end)

      assert Config.enabled?()
    end

    test "returns false for other values" do
      System.put_env("EVENT_WRITER_ENABLED", "false")
      on_exit(fn -> System.delete_env("EVENT_WRITER_ENABLED") end)

      refute Config.enabled?()
    end
  end

  describe "default_streams/0" do
    test "returns list of default stream configurations" do
      streams = Config.default_streams()

      assert is_list(streams)
      refute Enum.empty?(streams)

      # Check that expected streams are present
      stream_names = Enum.map(streams, & &1.name)
      assert "EVENTS" in stream_names
      assert "FALCO" in stream_names
      assert "TRIVY" in stream_names
      assert "OTEL_METRICS" in stream_names
      assert "OTEL_TRACES" in stream_names
      assert "LOGS" in stream_names
      assert "METRICS" in stream_names
      assert "BMP_CAUSAL" in stream_names
      assert "ARANCINI_CAUSAL" in stream_names
      assert "SIEM_CAUSAL" in stream_names
      assert "ANALYTICS_PREDICTIONS" in stream_names
      refute "ATTRIBUTED_FLOW" in stream_names
      # Raw flows are on the dedicated flow pipeline, not the shared demand domain.
      refute "NETFLOW_RAW" in stream_names
      refute "SFLOW_RAW" in stream_names
    end

    test "default_flow_streams targets the dedicated flows stream" do
      streams = Config.default_flow_streams()
      names = Enum.map(streams, & &1.name)

      assert "NETFLOW_RAW" in names
      assert "SFLOW_RAW" in names

      for stream <- streams do
        assert stream.stream_name == "flows"
        assert String.starts_with?(stream.subject, "flows.raw.")
        assert stream.consumer_pull_batch_size == Config.default_flow_pull_batch_size()
        assert stream.consumer_max_ack_pending == Config.default_flow_max_ack_pending()
        assert stream.stream_retention == "limits"
        assert stream.stream_discard == "old"
        # Must not fall back onto events or thrash collector-owned retention.
        assert stream.allow_stream_fallback == false
        assert stream.reconcile_stream_shape == false
      end
    end

    test "load_flow uses long-poll and independent demand knobs" do
      flow = Config.load_flow()

      assert Enum.all?(flow.streams, &Config.flow_stream?/1)
      assert flow.producer_name == ServiceRadar.EventWriter.FlowProducer
      assert flow.pull_expires_ns == Config.default_flow_pull_expires_ns()
      assert flow.consumer_pull_batch_size == Config.default_flow_pull_batch_size()
      assert flow.max_ack_pending == Config.default_flow_max_ack_pending()
    end

    test "routes raw Falco sidekick events from the dedicated Falco stream" do
      falco = Enum.find(Config.default_streams(), &(&1.name == "FALCO"))

      assert falco.stream_name == "events"
      assert falco.subject == "falco.logs"
      assert falco.processor == ServiceRadar.EventWriter.Processors.FalcoEvents
    end

    test "does not declare the retired attributed-flow read-back stream" do
      refute Enum.any?(Config.default_streams(), &(&1.subject == "flow.attributed.>"))
    end

    test "routes ad-hoc scan results from a dedicated stream" do
      scan = Enum.find(Config.default_streams(), &(&1.name == "SCAN_RESULTS"))

      assert scan.stream_name == "scan_results"
      assert scan.subject == "scans.results.>"
      assert scan.processor == ServiceRadar.EventWriter.Processors.AdhocScan
      # Must NOT overlap the metrics stream, or the Metrics processor would
      # try to decode scan rows as protobuf metric envelopes.
      refute String.starts_with?(scan.subject, "metrics.")
    end

    test "consumes analytics prediction verdicts from a dedicated retention stream" do
      analytics_predictions =
        Enum.find(Config.default_streams(), &(&1.name == "ANALYTICS_PREDICTIONS"))

      # default_streams/0 must splice the shared definition verbatim (both
      # runtime.exs trees consume the same function).
      assert analytics_predictions == Config.analytics_predictions_stream()

      # Literal guard on the shared definition: a bad edit to
      # analytics_predictions_stream/0 must fail here, not just self-compare.
      assert analytics_predictions.stream_name == "analytics_predictions"
      assert analytics_predictions.subject == "signals.analytics.predictions.>"

      assert analytics_predictions.processor ==
               ServiceRadar.EventWriter.Processors.AnalyticsSignals

      # Verdicts must survive core outages >30m: the shared events stream's
      # MaxAge is pinned to 30m by the otel collector, so the dedicated stream
      # carries its own bounded discard-old retention (1 GiB / 24h).
      assert analytics_predictions.stream_retention == "limits"
      assert analytics_predictions.stream_storage == "file"
      assert analytics_predictions.stream_discard == "old"
      assert analytics_predictions.stream_max_bytes == 1_073_741_824
      assert analytics_predictions.stream_max_age == 86_400_000_000_000
    end

    test "routes host metrics through a dedicated limits-retention stream" do
      metrics = Enum.find(Config.default_streams(), &(&1.name == "METRICS"))

      assert metrics.stream_name == "metrics"
      assert metrics.subject == "metrics.>"
      assert metrics.processor == ServiceRadar.EventWriter.Processors.Metrics
      assert metrics.batch_size == 500
      assert metrics.batch_timeout == 500
      assert metrics.stream_retention == "limits"
      assert metrics.stream_storage == "file"
      assert metrics.stream_discard == "old"
      assert metrics.stream_max_bytes == 1_073_741_824
      assert metrics.stream_max_age == 1_800_000_000_000
      assert metrics.consumer_pull_batch_size == 64
      assert metrics.consumer_max_deliver == 5
      refute metrics.stream_retention == "workqueue"
    end

    test "each stream has required fields" do
      for stream <- Config.default_streams() do
        assert Map.has_key?(stream, :name)
        assert Map.has_key?(stream, :subject)
        assert Map.has_key?(stream, :processor)
        assert Map.has_key?(stream, :batch_size)
        assert Map.has_key?(stream, :batch_timeout)
      end
    end

    test "stream processors are valid modules" do
      for stream <- Config.default_streams() do
        assert is_atom(stream.processor)
        # Processor module name should contain "Processors"
        assert String.contains?(Atom.to_string(stream.processor), "Processors")
      end
    end
  end

  describe "load/0" do
    test "returns Config struct" do
      config = Config.load()

      assert %Config{} = config
      assert is_boolean(config.enabled)
      assert is_map(config.nats)
      assert is_integer(config.batch_size)
      assert is_integer(config.batch_timeout)
      assert is_binary(config.consumer_name)
      assert is_list(config.streams)
    end

    test "loads default NATS configuration" do
      config = Config.load()

      assert config.nats.host == "localhost"
      assert config.nats.port == 4222
    end

    test "builds stable durable names for stream configs" do
      assert Config.durable_name("serviceradar-event-writer", "OTEL_METRICS") ==
               "serviceradar-event-writer-otel-metrics"

      assert Config.durable_name("serviceradar-event-writer", "ARANCINI_CAUSAL") ==
               "serviceradar-event-writer-arancini-causal"
    end

    test "uses default batch settings" do
      config = Config.load()

      assert config.batch_size == 100
      assert config.batch_timeout == 1000
    end

    test "uses default consumer name" do
      config = Config.load()

      assert config.consumer_name == "serviceradar-event-writer"
    end

    test "parses NATS URL from environment" do
      System.put_env("EVENT_WRITER_NATS_URL", "nats://custom-host:5222")
      on_exit(fn -> System.delete_env("EVENT_WRITER_NATS_URL") end)

      config = Config.load()

      assert config.nats.host == "custom-host"
      assert config.nats.port == 5222
    end

    test "parses batch settings from environment" do
      System.put_env("EVENT_WRITER_BATCH_SIZE", "200")
      System.put_env("EVENT_WRITER_BATCH_TIMEOUT", "2000")

      on_exit(fn ->
        System.delete_env("EVENT_WRITER_BATCH_SIZE")
        System.delete_env("EVENT_WRITER_BATCH_TIMEOUT")
      end)

      config = Config.load()

      assert config.batch_size == 200
      assert config.batch_timeout == 2000
    end

    test "parses consumer name from environment" do
      System.put_env("EVENT_WRITER_CONSUMER_NAME", "custom-consumer")
      on_exit(fn -> System.delete_env("EVENT_WRITER_CONSUMER_NAME") end)

      config = Config.load()

      assert config.consumer_name == "custom-consumer"
    end
  end

  describe "flow-control configuration" do
    test "defaults bound in-flight tightly, not at the old 5000" do
      config = Config.load()

      assert config.max_ack_pending == 256
      assert config.consumer_pull_batch_size == 16
      assert config.max_ack_pending < 5_000
      assert config.processor_concurrency == 10
      assert config.ack_wait_ns == 120_000_000_000
      assert config.max_deliver == 5
    end

    test "exposes the documented defaults" do
      assert Config.default_max_ack_pending() == 256
      assert Config.default_consumer_pull_batch_size() == 16
      assert Config.default_processor_concurrency() == 10
      assert Config.default_ack_wait_ns() == 120_000_000_000
      assert Config.default_max_deliver() == 5
    end

    test "max_ack_pending is tunable from the environment without a rebuild" do
      System.put_env("EVENT_WRITER_MAX_ACK_PENDING", "512")
      on_exit(fn -> System.delete_env("EVENT_WRITER_MAX_ACK_PENDING") end)

      assert Config.load().max_ack_pending == 512
    end

    test "pull batch size is tunable from the environment without a rebuild" do
      System.put_env("EVENT_WRITER_CONSUMER_PULL_BATCH_SIZE", "32")
      on_exit(fn -> System.delete_env("EVENT_WRITER_CONSUMER_PULL_BATCH_SIZE") end)

      assert Config.load().consumer_pull_batch_size == 32
    end

    test "processor concurrency is tunable from the environment" do
      System.put_env("EVENT_WRITER_PROCESSOR_CONCURRENCY", "20")
      on_exit(fn -> System.delete_env("EVENT_WRITER_PROCESSOR_CONCURRENCY") end)

      assert Config.load().processor_concurrency == 20
    end

    test "ack_wait is configured in seconds and stored as nanoseconds" do
      System.put_env("EVENT_WRITER_ACK_WAIT_SECONDS", "90")
      on_exit(fn -> System.delete_env("EVENT_WRITER_ACK_WAIT_SECONDS") end)

      assert Config.load().ack_wait_ns == 90_000_000_000
    end

    test "max_deliver is tunable from the environment" do
      System.put_env("EVENT_WRITER_MAX_DELIVER", "3")
      on_exit(fn -> System.delete_env("EVENT_WRITER_MAX_DELIVER") end)

      assert Config.load().max_deliver == 3
    end

    test "invalid or non-positive env values fall back to safe defaults" do
      System.put_env("EVENT_WRITER_MAX_ACK_PENDING", "0")
      System.put_env("EVENT_WRITER_PROCESSOR_CONCURRENCY", "not-a-number")

      on_exit(fn ->
        System.delete_env("EVENT_WRITER_MAX_ACK_PENDING")
        System.delete_env("EVENT_WRITER_PROCESSOR_CONCURRENCY")
      end)

      config = Config.load()
      assert config.max_ack_pending == 256
      assert config.processor_concurrency == 10
    end
  end

  describe "stream retention guard" do
    test "the shared events stream has a bounded discard-old retention policy" do
      events = Enum.find(Config.default_streams(), &(&1.name == "EVENTS"))

      assert events.stream_retention == "limits"
      assert events.stream_discard == "old"
      assert is_integer(events.stream_max_bytes) and events.stream_max_bytes > 0
      assert is_integer(events.stream_max_age) and events.stream_max_age > 0
    end

    test "ARANCINI_CAUSAL retention is left untouched" do
      arancini = Enum.find(Config.default_streams(), &(&1.name == "ARANCINI_CAUSAL"))

      refute Map.has_key?(arancini, :stream_max_bytes)
      refute Map.has_key?(arancini, :stream_discard)
    end
  end
end
