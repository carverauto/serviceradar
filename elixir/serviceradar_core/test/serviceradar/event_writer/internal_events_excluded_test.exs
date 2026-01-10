defmodule ServiceRadar.EventWriter.InternalEventsExcludedTest do
  @moduledoc """
  Verifies that internal health events are NOT routed through NATS.

  This test confirms that:
  1. EventWriter default streams only include external ingestion subjects
  2. Internal health event subjects are NOT in the subscription list
  3. HealthTracker writes directly to CNPG without NATS

  Satisfies task 4.2 from the remove-nats-internal-events proposal.
  """

  use ExUnit.Case, async: true

  alias ServiceRadar.EventWriter.Config

  describe "EventWriter stream configuration" do
    test "default streams include only external ingestion subjects" do
      streams = Config.default_streams()

      # Verify we have the expected external streams
      stream_names = Enum.map(streams, & &1.name)

      assert "EVENTS" in stream_names or "EVENTS_LEGACY" in stream_names
      assert "LOGS" in stream_names or "LOGS_LEGACY" in stream_names
      assert "OTEL_METRICS" in stream_names or "OTEL_METRICS_LEGACY" in stream_names
      assert "OTEL_TRACES" in stream_names or "OTEL_TRACES_LEGACY" in stream_names
    end

    test "default streams do NOT include internal health subjects" do
      streams = Config.default_streams()
      subjects = Enum.map(streams, & &1.subject)

      # These patterns would match internal health events if they were routed through NATS
      internal_patterns = [
        "*.health.>",
        "health.>",
        "*.internal.>",
        "internal.>",
        "*.health_events.>",
        "health_events.>",
        "*.state_changes.>",
        "state_changes.>"
      ]

      for subject <- subjects do
        refute subject in internal_patterns,
               "EventWriter should not subscribe to internal health subject: #{subject}"
      end
    end

    test "stream subjects only match external data patterns" do
      streams = Config.default_streams()

      for stream <- streams do
        # All subjects should be for external data: events, logs, otel, netflow, etc.
        # NOT for internal health/state changes
        assert stream.subject =~ ~r/\.(events|logs|otel|netflow|sweep|telemetry)\./,
               "Stream #{stream.name} has subject #{stream.subject} which may not be for external data"
      end
    end
  end

  describe "internal health event flow" do
    @tag :source_analysis
    test "HealthTracker does not depend on NATS modules" do
      # Verify HealthTracker doesn't import or alias NATS-related modules
      # This is a static check to ensure the module design is correct
      tracker_path =
        Path.join([
          Application.app_dir(:serviceradar_core),
          "..",
          "lib/serviceradar/infrastructure/health_tracker.ex"
        ])
        |> Path.expand()

      {:ok, tracker_source} = File.read(tracker_path)

      # Should NOT reference NATS publishing modules
      refute tracker_source =~ ~r/alias.*EventPublisher/,
             "HealthTracker should not alias EventPublisher (NATS)"

      refute tracker_source =~ ~r/alias.*EventBatcher/,
             "HealthTracker should not alias EventBatcher (NATS)"

      refute tracker_source =~ ~r/alias.*Jetstream/,
             "HealthTracker should not reference Jetstream"

      refute tracker_source =~ ~r/NATS\.publish/,
             "HealthTracker should not call NATS.publish"

      # SHOULD reference HealthEvent and PubSub (internal, not NATS)
      assert tracker_source =~ ~r/alias.*HealthEvent/,
             "HealthTracker should alias HealthEvent"

      assert tracker_source =~ ~r/alias.*HealthPubSub/,
             "HealthTracker should alias HealthPubSub"
    end

    @tag :source_analysis
    test "HealthPubSub uses Phoenix.PubSub, not NATS" do
      pubsub_path =
        Path.join([
          Application.app_dir(:serviceradar_core),
          "..",
          "lib/serviceradar/infrastructure/health_pubsub.ex"
        ])
        |> Path.expand()

      {:ok, pubsub_source} = File.read(pubsub_path)

      # Should use Phoenix.PubSub
      assert pubsub_source =~ ~r/Phoenix\.PubSub\.broadcast/,
             "HealthPubSub should use Phoenix.PubSub.broadcast"

      # Should NOT use NATS
      refute pubsub_source =~ ~r/NATS/,
             "HealthPubSub should not reference NATS"
    end
  end
end
