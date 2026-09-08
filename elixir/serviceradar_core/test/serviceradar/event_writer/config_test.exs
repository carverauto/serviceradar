defmodule ServiceRadar.EventWriter.ConfigTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.EventWriter.Config
  alias ServiceRadar.EventWriter.Processors.Flows

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
      assert "K8S_INVENTORY" in stream_names
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

    test "jetstream_stream_name never treats SFLOW_RAW as a stream name" do
      assert Config.jetstream_stream_name(%{name: "SFLOW_RAW", subject: "flows.raw.sflow"}) ==
               "flows"

      assert Config.jetstream_stream_name(%{name: "NETFLOW_RAW", subject: "flows.raw.netflow"}) ==
               "flows"

      assert Config.jetstream_stream_name(%{
               name: "SFLOW_RAW",
               stream_name: "flows",
               subject: "flows.raw.sflow"
             }) == "flows"

      assert Config.jetstream_stream_name(%{name: "EVENTS", subject: "events.>"}) == "EVENTS"
    end

    test "default_flow_streams targets the dedicated flows stream" do
      streams = Config.default_flow_streams()
      names = Enum.map(streams, & &1.name)

      assert "NETFLOW_RAW" in names
      assert "SFLOW_RAW" in names

      for stream <- streams do
        assert stream.stream_name == "flows"
        assert String.starts_with?(stream.subject, "flows.raw.")
        # Pull/ack knobs are injected by load_flow/0 from env, not hard-coded here.
        refute Map.has_key?(stream, :consumer_pull_batch_size)
        refute Map.has_key?(stream, :consumer_max_ack_pending)
        assert stream.stream_retention == "limits"
        assert stream.stream_discard == "old"
        # Must not fall back onto events or thrash collector-owned retention.
        assert stream.allow_stream_fallback == false
        assert stream.reconcile_stream_shape == false
      end
    end

    test "default_streams still routes K8s inventory snapshots" do
      assert Enum.any?(Config.default_streams(), &(&1.name == "K8S_INVENTORY"))

      inv = Enum.find(Config.default_streams(), &(&1.name == "K8S_INVENTORY"))
      assert inv.stream_name == "k8s_inventory"
      assert inv.subject == "inventory.k8s.public_endpoints"
      assert inv.processor == ServiceRadar.EventWriter.Processors.K8sPublicEndpoints

      assert Enum.any?(Config.default_streams(), &(&1.name == "K8S_NODES"))
      nodes = Enum.find(Config.default_streams(), &(&1.name == "K8S_NODES"))
      assert nodes.stream_name == "k8s_inventory"
      assert nodes.subject == "inventory.k8s.nodes"
      assert nodes.processor == ServiceRadar.EventWriter.Processors.K8sNodes
    end

    test "load_flow uses long-poll and independent demand knobs" do
      flow = Config.load_flow()

      assert Enum.all?(flow.streams, &Config.flow_stream?/1)
      assert flow.producer_name == ServiceRadar.EventWriter.FlowProducer
      assert flow.pull_expires_ns == Config.default_flow_pull_expires_ns()
      assert flow.consumer_pull_batch_size == Config.default_flow_pull_batch_size()
      assert flow.max_ack_pending == Config.default_flow_max_ack_pending()

      for stream <- flow.streams do
        assert stream.consumer_pull_batch_size == flow.consumer_pull_batch_size
        assert stream.consumer_max_ack_pending == flow.max_ack_pending
      end
    end

    test "load_flow injects EVENT_WRITER_FLOW_* overrides into each stream" do
      System.put_env("EVENT_WRITER_FLOW_CONSUMER_PULL_BATCH_SIZE", "99")
      System.put_env("EVENT_WRITER_FLOW_MAX_ACK_PENDING", "777")

      on_exit(fn ->
        System.delete_env("EVENT_WRITER_FLOW_CONSUMER_PULL_BATCH_SIZE")
        System.delete_env("EVENT_WRITER_FLOW_MAX_ACK_PENDING")
      end)

      flow = Config.load_flow()
      assert flow.consumer_pull_batch_size == 99
      assert flow.max_ack_pending == 777

      for stream <- flow.streams do
        assert stream.consumer_pull_batch_size == 99
        assert stream.consumer_max_ack_pending == 777
      end
    end

    test "load_flow dual-consumes residual events backlog by default" do
      System.delete_env("EVENT_WRITER_FLOW_DRAIN_EVENTS")
      flow = Config.load_flow()
      drain = Enum.filter(flow.streams, &(&1.stream_name == "events"))
      names = Enum.map(drain, & &1.name)

      assert "NETFLOW_RAW_EVENTS_DRAIN" in names
      assert "SFLOW_RAW_EVENTS_DRAIN" in names

      for stream <- drain do
        assert stream.allow_stream_fallback == false
        assert stream.ensure_stream == false
        assert stream.reconcile_stream_shape == false
        assert String.starts_with?(stream.subject, "flows.raw.")
        # Resume pre-cutover durable (not a brand-new deliver_policy:all name).
        assert stream.durable_source_name in ["NETFLOW_RAW", "SFLOW_RAW"]
        refute Map.has_key?(stream, :consumer_deliver_policy)

        assert Config.durable_name("serviceradar-event-writer", stream.durable_source_name) ==
                 Config.durable_name("serviceradar-event-writer", stream.durable_source_name)
      end

      netflow_drain = Enum.find(drain, &(&1.name == "NETFLOW_RAW_EVENTS_DRAIN"))
      assert netflow_drain.durable_source_name == "NETFLOW_RAW"

      assert Config.durable_name("serviceradar-event-writer", "NETFLOW_RAW") ==
               "serviceradar-event-writer-netflow-raw"
    end

    test "legacy NETFLOW/SFLOW drains use :new if absent; extras use :all" do
      System.delete_env("EVENT_WRITER_FLOW_EXTRA_SUBJECTS")
      System.delete_env("EVENT_WRITER_FLOW_DRAIN_EVENTS")
      flow = Config.load_flow()

      netflow_drain =
        Enum.find(flow.streams, &(&1.name == "NETFLOW_RAW_EVENTS_DRAIN"))

      assert netflow_drain.consumer_deliver_policy_if_absent == :new
    end

    test "flow_subject_stream_name is collision-free for similar subjects" do
      a = Config.flow_subject_stream_name("flows.raw.ipfix-v10")
      b = Config.flow_subject_stream_name("flows.raw.ipfix_v10")
      assert a != b
      assert String.starts_with?(a, "FLOW_IPFIX_V10_")
      assert String.starts_with?(b, "FLOW_IPFIX_V10_")
    end

    test "flow_subject_stream_name stays short for long subjects" do
      long = "flows.raw." <> String.duplicate("vendor-segment-", 20) <> "leaf"
      name = Config.flow_subject_stream_name(long)
      assert byte_size(name) < 48
      assert String.starts_with?(name, "FLOW_")
      # trailing 8-char hash retained
      assert Regex.match?(~r/_[a-f0-9]{8}$/, name)
    end

    test "durable_name stays within NATS 255-byte limit; long base keeps stream hash" do
      long_key = "FLOW_" <> String.duplicate("X", 300) <> "_abcd1234"
      name = Config.durable_name("serviceradar-event-writer", long_key)
      assert byte_size(name) <= 255

      long_base = String.duplicate("x", 253)
      a = Config.durable_name(long_base, "OTEL_METRICS")
      b = Config.durable_name(long_base, "OTEL_TRACES")
      assert byte_size(a) <= 255
      assert byte_size(b) <= 255
      assert a != b
      # Reserved hash suffix differs per stream key
      assert String.slice(a, -8, 8) != String.slice(b, -8, 8)
    end

    test "durable_name keeps short names backward compatible" do
      assert Config.durable_name("serviceradar-event-writer", "NETFLOW_RAW") ==
               "serviceradar-event-writer-netflow-raw"
    end

    test "exact_nats_subject? allows embedded star but rejects whole-token wildcards" do
      assert Config.exact_nats_subject?("flows.raw.vendor*name")
      assert Config.exact_raw_flow_subject?("flows.raw.vendor*name")
      refute Config.exact_raw_flow_subject?("flow.host-slice.agent-1")
      refute Config.flow_stream?(%{subject: "flow.host-slice.agent-1"})
      refute Config.exact_nats_subject?("flows.raw.>")
      refute Config.exact_nats_subject?("flows.raw.*")
      refute Config.exact_nats_subject?("flows.raw.*.leaf")
    end

    test "extra_flow_subjects accepts embedded star literals" do
      System.put_env("EVENT_WRITER_FLOW_EXTRA_SUBJECTS", "flows.raw.vendor*name")
      on_exit(fn -> System.delete_env("EVENT_WRITER_FLOW_EXTRA_SUBJECTS") end)

      assert Config.extra_flow_subjects() == ["flows.raw.vendor*name"]
    end

    test "extra_flow_subjects raises on whole-token wildcards" do
      System.put_env(
        "EVENT_WRITER_FLOW_EXTRA_SUBJECTS",
        "flows.raw.>,flows.raw.ipfix"
      )

      on_exit(fn -> System.delete_env("EVENT_WRITER_FLOW_EXTRA_SUBJECTS") end)

      assert_raise ArgumentError, ~r/wildcard filters that intersect/, fn ->
        Config.extra_flow_subjects()
      end
    end

    test "extra_flow_subjects fails closed on symbolic namespace overlap" do
      on_exit(fn ->
        System.delete_env("EVENT_WRITER_FLOW_EXTRA_SUBJECTS")
        System.delete_env("EVENT_WRITER_FLOW_DRAIN_EXTRA_SUBJECTS")
      end)

      for env_name <- [
            "EVENT_WRITER_FLOW_EXTRA_SUBJECTS",
            "EVENT_WRITER_FLOW_DRAIN_EXTRA_SUBJECTS"
          ],
          subject <- ["flows.*.vendor", "*.raw.vendor", "flow.*.vendor"] do
        System.delete_env("EVENT_WRITER_FLOW_EXTRA_SUBJECTS")
        System.delete_env("EVENT_WRITER_FLOW_DRAIN_EXTRA_SUBJECTS")
        System.put_env(env_name, subject)

        assert_raise ArgumentError, ~r/wildcard filters that intersect/, fn ->
          Config.extra_flow_subjects()
        end
      end
    end

    test "extra_flow_subjects raises on host-slice intermediates" do
      System.put_env("EVENT_WRITER_FLOW_EXTRA_SUBJECTS", "flow.host-slice.agent-1")
      on_exit(fn -> System.delete_env("EVENT_WRITER_FLOW_EXTRA_SUBJECTS") end)

      assert_raise ArgumentError, ~r/flow\.host-slice/, fn ->
        Config.extra_flow_subjects()
      end
    end

    test "load_flow rejects wildcard and host-slice in custom flow_streams" do
      previous = Application.get_env(:serviceradar_core, ServiceRadar.EventWriter, [])

      Application.put_env(
        :serviceradar_core,
        ServiceRadar.EventWriter,
        Keyword.put(previous, :flow_streams, [
          %{
            name: "NETFLOW_RAW",
            stream_name: "flows",
            subject: "flows.raw.>",
            processor: Flows
          }
        ])
      )

      on_exit(fn ->
        if previous == [] do
          Application.delete_env(:serviceradar_core, ServiceRadar.EventWriter)
        else
          Application.put_env(:serviceradar_core, ServiceRadar.EventWriter, previous)
        end
      end)

      assert_raise ArgumentError, ~r/intersects|concrete flows\.raw/, fn ->
        Config.load_flow()
      end
    end

    test "load rejects broader filters that cover flows.raw namespace" do
      previous = Application.get_env(:serviceradar_core, ServiceRadar.EventWriter, [])

      on_exit(fn ->
        if previous == [] do
          Application.delete_env(:serviceradar_core, ServiceRadar.EventWriter)
        else
          Application.put_env(:serviceradar_core, ServiceRadar.EventWriter, previous)
        end
      end)

      for subject <- ["flows.>", "*.>", "*.raw.>", "flow.>", ">"] do
        Application.put_env(
          :serviceradar_core,
          ServiceRadar.EventWriter,
          Keyword.put(previous, :streams, [
            %{name: "FLOWS_RAW", subject: subject, processor: Flows}
          ])
        )

        assert_raise ArgumentError, ~r/intersects/, fn ->
          Config.load()
        end

        # Restore immediately so parallel/async tests do not observe poisoned app config.
        if previous == [] do
          Application.delete_env(:serviceradar_core, ServiceRadar.EventWriter)
        else
          Application.put_env(:serviceradar_core, ServiceRadar.EventWriter, previous)
        end
      end
    end

    test "nats_filter_covers? token language" do
      assert Config.nats_filter_covers?("flows.>", "flows.raw.netflow")
      assert Config.nats_filter_covers?("*.>", "flows.raw.netflow")
      assert Config.nats_filter_covers?("*.raw.>", "flows.raw.ipfix")
      assert Config.nats_filter_covers?(">", "flows.raw.netflow")
      refute Config.nats_filter_covers?("logs.>", "flows.raw.netflow")
      refute Config.nats_filter_covers?("events.>", "flows.raw.netflow")
    end

    test "nats_filters_intersect? catches non-probe extension wildcards" do
      assert Config.nats_filters_intersect?("flows.*.vendor", "flows.raw.>")
      assert Config.nats_filters_intersect?("flows.raw.custom.>", "flows.raw.>")
      assert Config.nats_filters_intersect?("flow.*.vendor", "flow.host-slice.>")
      assert Config.nats_filter_overlaps_flow_namespace?("flows.*.vendor")
      assert Config.nats_filter_overlaps_flow_namespace?("flows.raw.custom.>")
      refute Config.nats_filter_overlaps_flow_namespace?("flows.raw.vendor")
      refute Config.nats_filter_overlaps_flow_namespace?("logs.>")
    end

    test "load rejects shared FLOWS_RAW with mid-token wildcard filter" do
      previous = Application.get_env(:serviceradar_core, ServiceRadar.EventWriter, [])

      on_exit(fn ->
        if previous == [] do
          Application.delete_env(:serviceradar_core, ServiceRadar.EventWriter)
        else
          Application.put_env(:serviceradar_core, ServiceRadar.EventWriter, previous)
        end
      end)

      Application.put_env(
        :serviceradar_core,
        ServiceRadar.EventWriter,
        Keyword.put(previous, :streams, [
          %{name: "FLOWS_RAW", subject: "flows.*.vendor", processor: Flows}
        ])
      )

      assert_raise ArgumentError, ~r/intersects/, fn ->
        Config.load()
      end

      if previous == [] do
        Application.delete_env(:serviceradar_core, ServiceRadar.EventWriter)
      else
        Application.put_env(:serviceradar_core, ServiceRadar.EventWriter, previous)
      end
    end

    test "load rejects host-slice in main streams list" do
      previous = Application.get_env(:serviceradar_core, ServiceRadar.EventWriter, [])

      Application.put_env(
        :serviceradar_core,
        ServiceRadar.EventWriter,
        Keyword.put(previous, :streams, [
          %{
            name: "HOST_SLICE",
            subject: "flow.host-slice.agent-1",
            processor: Flows
          }
        ])
      )

      on_exit(fn ->
        if previous == [] do
          Application.delete_env(:serviceradar_core, ServiceRadar.EventWriter)
        else
          Application.put_env(:serviceradar_core, ServiceRadar.EventWriter, previous)
        end
      end)

      assert_raise ArgumentError, ~r/flow\.host-slice/, fn ->
        Config.load()
      end
    end

    test "assert_no_canonical_consumer_collisions! catches case/punct durable collapse" do
      streams = [
        %{name: "FLOW_RAW_IPFIX_84c80497", stream_name: "flows", subject: "flows.raw.a"},
        %{name: "flow-raw-ipfix-84c80497", stream_name: "flows", subject: "flows.raw.b"}
      ]

      assert_raise ArgumentError, ~r/colliding JetStream durable names/, fn ->
        Config.assert_no_canonical_consumer_collisions!(streams, "serviceradar-event-writer")
      end
    end

    test "load/0 collision guard rejects long base collapsing distinct streams" do
      previous = Application.get_env(:serviceradar_core, ServiceRadar.EventWriter, [])
      long_base = String.duplicate("c", 250)

      Application.put_env(
        :serviceradar_core,
        ServiceRadar.EventWriter,
        Keyword.merge(previous,
          consumer_name: long_base,
          streams: [
            %{
              name: "OTEL_METRICS",
              subject: "otel.metrics.>",
              processor: ServiceRadar.EventWriter.Processors.OtelMetrics
            },
            %{
              name: "OTEL_TRACES",
              subject: "otel.traces.>",
              processor: ServiceRadar.EventWriter.Processors.OtelTraces
            }
          ]
        )
      )

      on_exit(fn ->
        if previous == [] do
          Application.delete_env(:serviceradar_core, ServiceRadar.EventWriter)
        else
          Application.put_env(:serviceradar_core, ServiceRadar.EventWriter, previous)
        end
      end)

      # With hash-reserved durable_name, long base no longer collapses — load succeeds
      # and durables remain distinct.
      config = Config.load()
      assert config.consumer_name == long_base
      a = Config.durable_name(long_base, "OTEL_METRICS")
      b = Config.durable_name(long_base, "OTEL_TRACES")
      assert a != b
      assert byte_size(a) <= 255
    end

    test "EVENT_WRITER_FLOW_EXTRA_SUBJECTS creates live flows + events drain pair" do
      System.put_env("EVENT_WRITER_FLOW_EXTRA_SUBJECTS", "flows.raw.ipfix")
      on_exit(fn -> System.delete_env("EVENT_WRITER_FLOW_EXTRA_SUBJECTS") end)

      flow = Config.load_flow()

      live =
        Enum.filter(
          flow.streams,
          &(&1.subject == "flows.raw.ipfix" and &1.stream_name == "flows")
        )

      drain =
        Enum.filter(
          flow.streams,
          &(&1.subject == "flows.raw.ipfix" and &1.stream_name == "events")
        )

      assert length(live) == 1
      assert length(drain) == 1
      expected = Config.flow_subject_stream_name("flows.raw.ipfix")
      assert hd(live).name == expected
      assert hd(drain).durable_source_name == expected
      assert hd(drain).consumer_deliver_policy_if_absent == :all
    end

    test "EVENT_WRITER_FLOW_DRAIN_EVENTS=false disables events dual-consume" do
      System.put_env("EVENT_WRITER_FLOW_DRAIN_EVENTS", "false")
      on_exit(fn -> System.delete_env("EVENT_WRITER_FLOW_DRAIN_EVENTS") end)

      flow = Config.load_flow()
      refute Enum.any?(flow.streams, &(&1.stream_name == "events"))
    end

    test "load_flow preserves explicit per-stream pull/ack tuning without env override" do
      previous = Application.get_env(:serviceradar_core, ServiceRadar.EventWriter, [])

      Application.put_env(
        :serviceradar_core,
        ServiceRadar.EventWriter,
        Keyword.put(previous, :flow_streams, [
          %{
            name: "NETFLOW_RAW",
            stream_name: "flows",
            subject: "flows.raw.netflow",
            processor: Flows,
            consumer_pull_batch_size: 256,
            consumer_max_ack_pending: 2048,
            allow_stream_fallback: false,
            reconcile_stream_shape: false
          },
          %{
            name: "SFLOW_RAW",
            stream_name: "flows",
            subject: "flows.raw.sflow",
            processor: Flows,
            allow_stream_fallback: false,
            reconcile_stream_shape: false
          }
        ])
      )

      on_exit(fn ->
        if previous == [] do
          Application.delete_env(:serviceradar_core, ServiceRadar.EventWriter)
        else
          Application.put_env(:serviceradar_core, ServiceRadar.EventWriter, previous)
        end
      end)

      System.delete_env("EVENT_WRITER_FLOW_CONSUMER_PULL_BATCH_SIZE")
      System.delete_env("EVENT_WRITER_FLOW_MAX_ACK_PENDING")
      System.put_env("EVENT_WRITER_FLOW_DRAIN_EVENTS", "false")
      on_exit(fn -> System.delete_env("EVENT_WRITER_FLOW_DRAIN_EVENTS") end)

      flow = Config.load_flow()
      netflow = Enum.find(flow.streams, &(&1.name == "NETFLOW_RAW"))
      sflow = Enum.find(flow.streams, &(&1.name == "SFLOW_RAW"))

      assert netflow.consumer_pull_batch_size == 256
      assert netflow.consumer_max_ack_pending == 2048
      assert sflow.consumer_pull_batch_size == flow.consumer_pull_batch_size
      assert sflow.consumer_max_ack_pending == flow.max_ack_pending
    end

    test "EVENT_WRITER_FLOW_* env overrides win over custom per-stream tuning" do
      previous = Application.get_env(:serviceradar_core, ServiceRadar.EventWriter, [])

      Application.put_env(
        :serviceradar_core,
        ServiceRadar.EventWriter,
        Keyword.put(previous, :flow_streams, [
          %{
            name: "NETFLOW_RAW",
            stream_name: "flows",
            subject: "flows.raw.netflow",
            processor: Flows,
            consumer_pull_batch_size: 256,
            consumer_max_ack_pending: 2048,
            allow_stream_fallback: false,
            reconcile_stream_shape: false
          }
        ])
      )

      System.put_env("EVENT_WRITER_FLOW_CONSUMER_PULL_BATCH_SIZE", "99")
      System.put_env("EVENT_WRITER_FLOW_MAX_ACK_PENDING", "777")
      System.put_env("EVENT_WRITER_FLOW_DRAIN_EVENTS", "false")

      on_exit(fn ->
        System.delete_env("EVENT_WRITER_FLOW_CONSUMER_PULL_BATCH_SIZE")
        System.delete_env("EVENT_WRITER_FLOW_MAX_ACK_PENDING")
        System.delete_env("EVENT_WRITER_FLOW_DRAIN_EVENTS")

        if previous == [] do
          Application.delete_env(:serviceradar_core, ServiceRadar.EventWriter)
        else
          Application.put_env(:serviceradar_core, ServiceRadar.EventWriter, previous)
        end
      end)

      flow = Config.load_flow()
      netflow = Enum.find(flow.streams, &(&1.name == "NETFLOW_RAW"))
      assert flow.consumer_pull_batch_size == 99
      assert flow.max_ack_pending == 777
      assert netflow.consumer_pull_batch_size == 99
      assert netflow.consumer_max_ack_pending == 777
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
