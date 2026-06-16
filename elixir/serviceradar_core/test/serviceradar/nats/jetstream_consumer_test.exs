defmodule ServiceRadar.NATS.JetstreamConsumerTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.NATS.JetstreamConsumer

  test "reconciled stream payload replaces narrower metric subjects with metrics wildcard" do
    config = %{
      "name" => "metrics",
      "subjects" => ["metrics.sysmon.*"],
      "retention" => "limits",
      "storage" => "file",
      "discard" => "old"
    }

    assert {:ok, payload} =
             JetstreamConsumer.reconciled_stream_payload(config, "metrics", "metrics.>",
               stream_max_age: 1_800_000_000_000,
               stream_max_bytes: 1_073_741_824
             )

    assert payload["subjects"] == ["metrics.>"]
    assert payload["max_age"] == 1_800_000_000_000
    assert payload["max_bytes"] == 1_073_741_824
    assert payload["retention"] == "limits"
    assert payload["storage"] == "file"
    assert payload["discard"] == "old"
  end

  test "reconciled stream payload preserves existing limits when no replacement is configured" do
    config = %{
      "name" => "metrics",
      "subjects" => ["metrics.>"],
      "max_age" => 1_800_000_000_000,
      "max_bytes" => 1_073_741_824,
      "num_replicas" => 3
    }

    assert {:ok, payload} =
             JetstreamConsumer.reconciled_stream_payload(
               config,
               "metrics",
               "metrics.snmp.>",
               []
             )

    assert payload["subjects"] == ["metrics.>"]
    assert payload["max_age"] == 1_800_000_000_000
    assert payload["max_bytes"] == 1_073_741_824
    assert payload["num_replicas"] == 3
  end

  test "reconciled stream payload preserves existing limits when replacement options are nil" do
    config = %{
      "name" => "events",
      "subjects" => ["events.>"],
      "retention" => "limits",
      "storage" => "file",
      "discard" => "old",
      "num_replicas" => 3,
      "max_age" => 604_800_000_000_000,
      "max_bytes" => 10_737_418_240
    }

    assert {:ok, payload} =
             JetstreamConsumer.reconciled_stream_payload(
               config,
               "events",
               "events.anomaly.metrics.>",
               stream_retention: nil,
               stream_storage: nil,
               stream_discard: nil,
               stream_replicas: nil,
               stream_max_age: nil,
               stream_max_bytes: nil
             )

    assert payload["subjects"] == ["events.>"]
    assert payload["retention"] == "limits"
    assert payload["storage"] == "file"
    assert payload["discard"] == "old"
    assert payload["num_replicas"] == 3
    assert payload["max_age"] == 604_800_000_000_000
    assert payload["max_bytes"] == 10_737_418_240
  end

  test "normalized subjects keeps non-overlapping subjects" do
    assert JetstreamConsumer.normalized_subjects(["metrics.sysmon.*"], "metrics.snmp.>") ==
             ["metrics.sysmon.*", "metrics.snmp.>"]
  end

  test "consumer payload carries declared durable config for create and update" do
    payload =
      JetstreamConsumer.consumer_payload(
        "events",
        "serviceradar-event-writer-CAUSAL_PREDICTIONS",
        "signals.causal.predictions.>",
        description: "causal predictions",
        deliver_policy: :all,
        max_deliver: 5,
        deliver_subject: "_INBOX.causal_predictions"
      )

    assert payload.stream_name == "events"
    assert payload.config.durable_name == "serviceradar-event-writer-CAUSAL_PREDICTIONS"
    assert payload.config.filter_subject == "signals.causal.predictions.>"
    assert payload.config.description == "causal predictions"
    assert payload.config.deliver_policy == :all
    assert payload.config.max_deliver == 5
    assert payload.config.deliver_subject == "_INBOX.causal_predictions"
  end

  test "consumer payload omits deliver_subject for pull durable consumers" do
    payload =
      JetstreamConsumer.consumer_payload(
        "metrics",
        "serviceradar-event-writer-metrics",
        "metrics.>",
        description: "metrics pull consumer",
        deliver_policy: :all,
        ack_wait: 120_000_000_000,
        max_ack_pending: 256,
        max_deliver: 5
      )

    assert payload.stream_name == "metrics"
    assert payload.config.durable_name == "serviceradar-event-writer-metrics"
    assert payload.config.filter_subject == "metrics.>"
    assert payload.config.description == "metrics pull consumer"
    assert payload.config.ack_wait == 120_000_000_000
    assert payload.config.max_ack_pending == 256
    assert payload.config.max_deliver == 5
    refute Map.has_key?(payload.config, :deliver_subject)
  end
end
