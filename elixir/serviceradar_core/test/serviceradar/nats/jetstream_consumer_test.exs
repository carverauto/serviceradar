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

  test "reconciled stream payload can skip shape thrash when collector owns retention" do
    config = %{
      "name" => "flows",
      "subjects" => ["flows.raw.sflow"],
      "max_age" => 7_200_000_000_000,
      "max_bytes" => 8_589_934_592,
      "num_replicas" => 3
    }

    assert {:ok, payload} =
             JetstreamConsumer.reconciled_stream_payload(
               config,
               "flows",
               "flows.raw.netflow",
               reconcile_stream_shape: false,
               stream_max_bytes: 53_687_091_200,
               stream_max_age: 21_600_000_000_000,
               stream_replicas: 1
             )

    assert payload["subjects"] == ["flows.raw.sflow", "flows.raw.netflow"]
    # Collector-owned limits must remain untouched.
    assert payload["max_bytes"] == 8_589_934_592
    assert payload["max_age"] == 7_200_000_000_000
    assert payload["num_replicas"] == 3
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

  test "scoped stream opts keep shape options for the requested stream" do
    opts = [
      stream_name: "analytics_predictions",
      stream_retention: "limits",
      stream_max_bytes: 1_073_741_824
    ]

    assert JetstreamConsumer.scoped_stream_opts(opts, "analytics_predictions") == opts
  end

  test "scoped stream opts keep shape options when only stream-name case normalization differs" do
    opts = [stream_name: "EVENTS", stream_retention: "limits", stream_max_bytes: 8_589_934_592]

    assert JetstreamConsumer.scoped_stream_opts(opts, "events") == opts
  end

  test "scoped stream opts drop shape options when discovery resolved a different stream" do
    opts = [
      stream_name: "analytics_predictions",
      consumer_name: "serviceradar-event-writer-analytics-predictions",
      filter_subject: "signals.analytics.predictions.>",
      stream_retention: "limits",
      stream_storage: "file",
      stream_discard: "old",
      stream_replicas: 1,
      stream_max_bytes: 1_073_741_824,
      stream_max_age: 86_400_000_000_000,
      stream_duplicate_window: 120_000_000_000
    ]

    scoped = JetstreamConsumer.scoped_stream_opts(opts, "events")

    assert Keyword.get(scoped, :stream_name) == "analytics_predictions"

    assert Keyword.get(scoped, :consumer_name) ==
             "serviceradar-event-writer-analytics-predictions"

    assert Keyword.get(scoped, :filter_subject) == "signals.analytics.predictions.>"

    for shape_opt <- [
          :stream_retention,
          :stream_storage,
          :stream_discard,
          :stream_replicas,
          :stream_max_bytes,
          :stream_max_age,
          :stream_duplicate_window
        ] do
      refute Keyword.has_key?(scoped, shape_opt),
             "expected #{inspect(shape_opt)} to be dropped for the fallback stream"
    end
  end

  test "scoped stream opts keep shape options when no stream was requested" do
    opts = [stream_max_bytes: 1_073_741_824]

    assert JetstreamConsumer.scoped_stream_opts(opts, "sflow_raw") == opts
  end

  test "normalized subjects keeps non-overlapping subjects" do
    assert JetstreamConsumer.normalized_subjects(["metrics.sysmon.*"], "metrics.snmp.>") ==
             ["metrics.sysmon.*", "metrics.snmp.>"]
  end

  test "normalized subjects treats tail wildcard as one-or-more trailing tokens" do
    assert JetstreamConsumer.normalized_subjects(["events.>"], "events.test") == ["events.>"]

    assert JetstreamConsumer.normalized_subjects(["events.>"], "events") == [
             "events.>",
             "events"
           ]
  end

  test "consumer payload carries declared durable config for create and update" do
    payload =
      JetstreamConsumer.consumer_payload(
        "events",
        "serviceradar-event-writer-ANALYTICS_PREDICTIONS",
        "signals.analytics.predictions.>",
        description: "analytics predictions",
        deliver_policy: :all,
        max_deliver: 5,
        deliver_subject: "_INBOX.analytics_predictions"
      )

    assert payload.stream_name == "events"
    assert payload.config.durable_name == "serviceradar-event-writer-ANALYTICS_PREDICTIONS"
    assert payload.config.filter_subject == "signals.analytics.predictions.>"
    assert payload.config.description == "analytics predictions"
    assert payload.config.deliver_policy == :all
    assert payload.config.max_deliver == 5
    assert payload.config.deliver_subject == "_INBOX.analytics_predictions"
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

  test "subject overlap errors are recognized by err_code and description" do
    assert JetstreamConsumer.subject_overlap_error?(%{
             "code" => 400,
             "err_code" => 10_065,
             "description" => "subjects overlap with an existing stream"
           })

    assert JetstreamConsumer.subject_overlap_error?(%{"err_code" => 10_065})
    assert JetstreamConsumer.subject_overlap_error?("subjects overlap with an existing stream")

    refute JetstreamConsumer.subject_overlap_error?(%{
             "code" => 400,
             "err_code" => 10_058,
             "description" => "stream name already in use"
           })

    refute JetstreamConsumer.subject_overlap_error?(:timeout)
  end

  test "flows.raw subjects bind to the dedicated flows stream even when fallback is off" do
    assert JetstreamConsumer.choose_requested_or_first_stream(
             "SFLOW_RAW",
             "flows.raw.sflow",
             ["flows", "events"],
             false
           ) == {:ok, "flows"}

    assert JetstreamConsumer.choose_requested_or_first_stream(
             "flows",
             "flows.raw.netflow",
             ["flows"],
             false
           ) == {:ok, "flows"}
  end

  test "flow cutover does not bind live consumers onto events" do
    assert JetstreamConsumer.choose_requested_or_first_stream(
             "flows",
             "flows.raw.sflow",
             ["events"],
             false
           ) == {:ok, "flows"}
  end

  test "a subject no stream owns is an empty discovery result, not a discovery error" do
    # nats-server encodes "no stream owns this subject" as `"streams": null`.
    assert JetstreamConsumer.stream_names_reply(
             {:ok,
              %{"type" => "io.nats.jetstream.api.v1.stream_names_response", "streams" => nil}}
           ) == {:ok, []}

    assert JetstreamConsumer.stream_names_reply({:ok, %{"streams" => ["events", 7]}}) ==
             {:ok, ["events"]}

    assert {:error, {:unexpected_stream_names_response, _}} =
             JetstreamConsumer.stream_names_reply({:ok, %{"total" => 0}})

    assert JetstreamConsumer.stream_names_reply({:error, :timeout}) == {:error, :timeout}
  end

  test "overlap fallback re-resolves onto the stream owning the subject" do
    assert JetstreamConsumer.overlap_fallback_stream({:ok, ["events"]}, "analytics_predictions") ==
             {:ok, "events"}

    assert JetstreamConsumer.overlap_fallback_stream(
             {:ok, ["analytics_predictions", "events"]},
             "analytics_predictions"
           ) == {:ok, "events"}
  end

  test "overlap fallback keeps the original error when discovery finds no other stream" do
    assert JetstreamConsumer.overlap_fallback_stream({:ok, []}, "analytics_predictions") ==
             :error

    assert JetstreamConsumer.overlap_fallback_stream(
             {:ok, ["analytics_predictions"]},
             "analytics_predictions"
           ) == :error

    assert JetstreamConsumer.overlap_fallback_stream({:error, :timeout}, "analytics_predictions") ==
             :error
  end

  test "immutable push pull consumer shape errors require durable recreation" do
    assert JetstreamConsumer.immutable_consumer_shape_error?(
             "can not update push consumer to pull based"
           )

    assert JetstreamConsumer.immutable_consumer_shape_error?(
             "can not update pull consumer to push based"
           )

    refute JetstreamConsumer.immutable_consumer_shape_error?("consumer already exists")
  end

  test "consumer_payload omits deliver_policy when unset" do
    payload =
      JetstreamConsumer.consumer_payload(
        "events",
        "serviceradar-event-writer-netflow-raw",
        "flows.raw.netflow",
        ack_policy: :explicit
      )

    refute Map.has_key?(payload.config, :deliver_policy)
    refute Map.has_key?(payload.config, "deliver_policy")
  end

  test "consumer_payload includes explicit deliver_policy for create" do
    payload =
      JetstreamConsumer.consumer_payload(
        "events",
        "serviceradar-event-writer-netflow-raw",
        "flows.raw.netflow",
        deliver_policy: :new
      )

    assert payload.config[:deliver_policy] == :new or payload.config["deliver_policy"] == :new
  end

  test "consumer payload preserves an explicit by-start-sequence cursor" do
    payload =
      JetstreamConsumer.consumer_payload(
        "NOTIFICATIONS",
        "sr-firehose-v2-client",
        "notifications.stream",
        deliver_policy: :by_start_sequence,
        opt_start_seq: 42
      )

    assert payload.config.deliver_policy == :by_start_sequence
    assert payload.config.opt_start_seq == 42
  end

  test "deliver_policy_immutable_error? matches NATS 10012" do
    assert JetstreamConsumer.deliver_policy_immutable_error?(%{"err_code" => 10_012})
    assert JetstreamConsumer.deliver_policy_immutable_error?("deliver policy can not be updated")
  end
end
