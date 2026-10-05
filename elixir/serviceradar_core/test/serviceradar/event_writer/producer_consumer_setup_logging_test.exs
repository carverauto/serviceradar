defmodule ServiceRadar.EventWriter.ProducerConsumerSetupLoggingTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ServiceRadar.EventWriter.Config
  alias ServiceRadar.EventWriter.Producer

  @moduletag :db_free

  defmodule FakeJetStreamConnection do
    @moduledoc false

    use GenServer

    def child_spec(test_pid) do
      %{
        id: __MODULE__,
        start: {__MODULE__, :start_link, [test_pid]},
        restart: :temporary
      }
    end

    def start_link(test_pid), do: GenServer.start_link(__MODULE__, test_pid)

    @impl true
    def init(test_pid), do: {:ok, %{test_pid: test_pid, request_count: 0, next_sid: 99}}

    @impl true
    def handle_call({:request, request}, _from, state) do
      inbox = "_INBOX.event-writer-test.#{state.request_count}"
      body = request.topic |> response_for() |> Jason.encode!()

      send(request.recipient, {:msg, %{topic: inbox, body: body}})
      send(state.test_pid, {:jetstream_request, request.topic})

      {:reply, {:ok, inbox}, %{state | request_count: state.request_count + 1}}
    end

    def handle_call({:unsub, sid, _opts}, _from, state) do
      send(state.test_pid, {:unsubscribed, sid})
      {:reply, :ok, state}
    end

    def handle_call({:sub, _subscriber, topic, _opts}, _from, state) do
      sid = state.next_sid
      send(state.test_pid, {:subscribed, sid, topic})
      {:reply, {:ok, sid}, %{state | next_sid: sid + 1}}
    end

    defp response_for("$JS.API.STREAM.NAMES"), do: %{"streams" => ["flows"]}

    defp response_for("$JS.API.STREAM.CREATE.flows") do
      %{"type" => "io.nats.jetstream.api.v1.stream_create_response"}
    end

    defp response_for(topic) do
      cond do
        String.contains?(topic, ".CONSUMER.INFO.") ->
          %{"error" => %{"code" => 404, "description" => "consumer not found"}}

        String.contains?(topic, ".CONSUMER.DURABLE.CREATE.") ->
          %{"type" => "io.nats.jetstream.api.v1.consumer_create_response"}

        String.ends_with?(topic, ".CONSUMER.DELETE.events.already-gone") ->
          %{
            "error" => %{
              "code" => 404,
              "err_code" => 10_014,
              "description" => "consumer not found"
            }
          }

        String.ends_with?(topic, ".CONSUMER.DELETE.events.server-refuses") ->
          %{"error" => %{"code" => 500, "description" => "jetstream unavailable"}}

        String.contains?(topic, ".CONSUMER.DELETE.") ->
          %{"type" => "io.nats.jetstream.api.v1.consumer_delete_response", "success" => true}

        true ->
          raise "unexpected JetStream request: #{topic}"
      end
    end
  end

  test "best-effort setup failures warn without an error and preserve healthy consumers" do
    healthy_stream = %{
      name: "NETFLOW_RAW",
      stream_name: "flows",
      subject: "flows.raw.netflow"
    }

    drain_stream = %{
      name: "NETFLOW_RAW_EVENTS_DRAIN",
      stream_name: "events",
      subject: "flows.raw.netflow",
      durable_source_name: "NETFLOW_RAW",
      ensure_stream: false,
      best_effort: true
    }

    config = %Config{
      consumer_name: "serviceradar-event-writer",
      consumer_pull_batch_size: 64,
      streams: [healthy_stream, drain_stream]
    }

    conn = start_supervised!({FakeJetStreamConnection, self()})
    pull_subject = "_INBOX.serviceradar.event_writer.pull.serviceradar-event-writer.netflow_raw"

    log =
      capture_log([level: :debug], fn ->
        assert {:ok,
                %{
                  conn: ^conn,
                  consumer_name: "serviceradar-event-writer",
                  consumers: [
                    %{
                      stream: "flows",
                      durable: "serviceradar-event-writer-netflow-raw",
                      sid: 99,
                      subject: "flows.raw.netflow",
                      pull_subject: ^pull_subject,
                      pull_batch_size: 64
                    }
                  ],
                  pull_subjects: pull_subjects,
                  sid_to_pull_subject: %{99 => ^pull_subject}
                }} = Producer.setup_jetstream_consumers(conn, config)

        assert pull_subjects == MapSet.new([pull_subject])
      end)

    assert log =~ "[warning]"
    assert log =~ "EventWriter skipping best-effort drain consumer"
    assert log =~ ~s(name="NETFLOW_RAW_EVENTS_DRAIN")
    assert log =~ ~s(durable="serviceradar-event-writer-netflow-raw")
    assert log =~ ~s(stream="events")
    assert log =~ ~s(filter_subject="flows.raw.netflow")
    assert log =~ ~s(expected: "events")
    assert log =~ ~s(resolved: "flows")
    assert length(Regex.scan(~r/EventWriter skipping best-effort drain consumer/, log)) == 1
    refute log =~ "[error]"
    refute log =~ "Failed to initialize EventWriter durable consumer"
    assert Process.alive?(conn)

    assert_receive {:jetstream_request, "$JS.API.STREAM.NAMES"}

    assert_receive {:jetstream_request, "$JS.API.STREAM.CREATE.flows"}

    assert_receive {:jetstream_request,
                    "$JS.API.CONSUMER.INFO.flows.serviceradar-event-writer-netflow-raw"}

    assert_receive {:jetstream_request,
                    "$JS.API.CONSUMER.DURABLE.CREATE.flows.serviceradar-event-writer-netflow-raw"}

    assert_receive {:subscribed, 99, ^pull_subject}

    assert_receive {:jetstream_request, "$JS.API.STREAM.NAMES"}

    assert_receive {:jetstream_request,
                    "$JS.API.CONSUMER.INFO.flows.serviceradar-event-writer-netflow-raw"}

    assert_receive {:jetstream_request,
                    "$JS.API.CONSUMER.DURABLE.CREATE.flows.serviceradar-event-writer-netflow-raw"}

    refute_received {:subscribed, 100, _topic}
    refute_received {:unsubscribed, 99}
  end

  test "a required setup failure logs an error and keeps the healthy consumers" do
    healthy_stream = %{
      name: "NETFLOW_RAW",
      stream_name: "flows",
      subject: "flows.raw.netflow"
    }

    required_stream = %{
      name: "NETFLOW_RAW_REQUIRED",
      stream_name: "events",
      subject: "flows.raw.netflow"
    }

    config = %Config{
      consumer_name: "serviceradar-event-writer",
      consumer_pull_batch_size: 64,
      streams: [healthy_stream, required_stream]
    }

    conn = start_supervised!({FakeJetStreamConnection, self()})
    pull_subject = "_INBOX.serviceradar.event_writer.pull.serviceradar-event-writer.netflow_raw"

    failure_reason =
      {"NETFLOW_RAW_REQUIRED", {:unexpected_stream, expected: "events", resolved: "flows"}}

    log =
      capture_log([level: :debug], fn ->
        assert {:ok,
                %{
                  consumers: [%{sid: 99, pull_subject: ^pull_subject}],
                  failed_streams: [{^required_stream, ^failure_reason}]
                }} = Producer.setup_jetstream_consumers(conn, config)
      end)

    assert log =~ "[error]"
    assert log =~ "Failed to initialize EventWriter durable consumer"
    assert log =~ ~s(name="NETFLOW_RAW_REQUIRED")
    assert log =~ ~s(durable="serviceradar-event-writer-netflow-raw-required")
    assert log =~ ~s(stream="events")
    assert log =~ ~s(filter_subject="flows.raw.netflow")
    assert log =~ ~s(expected: "events")
    assert log =~ ~s(resolved: "flows")
    assert length(Regex.scan(~r/Failed to initialize EventWriter durable consumer/, log)) == 1

    refute log =~ "skipping best-effort drain consumer"

    assert_receive {:subscribed, 99, ^pull_subject}
    refute_received {:unsubscribed, 99}
    assert Process.alive?(conn)
  end

  test "retired consumers are deleted once the live consumers are ready, and a failure is not fatal" do
    config = %Config{
      consumer_name: "serviceradar-event-writer",
      consumer_pull_batch_size: 64,
      streams: [%{name: "NETFLOW_RAW", stream_name: "flows", subject: "flows.raw.netflow"}],
      retired_consumers: [
        %{stream_name: "events", consumer_name: "log-promotion"},
        %{stream_name: "events", consumer_name: "already-gone"},
        %{stream_name: "events", consumer_name: "server-refuses"}
      ]
    }

    conn = start_supervised!({FakeJetStreamConnection, self()})

    log =
      capture_log(fn ->
        assert {:ok, %{conn: ^conn, consumers: [_live]}} =
                 Producer.setup_jetstream_consumers(conn, config)
      end)

    assert_received {:jetstream_request, "$JS.API.CONSUMER.DELETE.events.log-promotion"}
    assert_received {:jetstream_request, "$JS.API.CONSUMER.DELETE.events.already-gone"}
    assert_received {:jetstream_request, "$JS.API.CONSUMER.DELETE.events.server-refuses"}

    # An absent consumer is already retired; only the refused delete is a warning.
    assert log =~ "could not delete retired JetStream consumer events/server-refuses"
    refute log =~ "events/already-gone"
    assert Process.alive?(conn)
  end

  test "retired consumers are not touched when the live consumers fail to start" do
    config = %Config{
      consumer_name: "serviceradar-event-writer",
      consumer_pull_batch_size: 64,
      streams: [
        %{name: "NETFLOW_RAW_REQUIRED", stream_name: "events", subject: "flows.raw.netflow"}
      ],
      retired_consumers: [%{stream_name: "events", consumer_name: "log-promotion"}]
    }

    conn = start_supervised!({FakeJetStreamConnection, self()})

    [stream] = config.streams

    capture_log(fn ->
      assert {:error, {:consumer_setup_failed, [{^stream, {"NETFLOW_RAW_REQUIRED", _reason}}]}} =
               Producer.setup_jetstream_consumers(conn, config)
    end)

    refute_received {:jetstream_request, "$JS.API.CONSUMER.DELETE.events.log-promotion"}
  end

  test "an empty stream configuration rejects setup and closes the connection" do
    config = %Config{consumer_name: "serviceradar-event-writer", streams: []}
    conn = start_supervised!({FakeJetStreamConnection, self()})

    assert {:error, :no_streams_configured} =
             Producer.setup_jetstream_consumers(conn, config)

    refute Process.alive?(conn)
    refute_received {:jetstream_request, _topic}
    refute_received {:subscribed, _sid, _topic}
    refute_received {:unsubscribed, _sid}
  end

  defmodule PlacementFailingConnection do
    @moduledoc false
    # A JetStream server with room for every stream except `mtr_results`, whose
    # creation is refused with err 10005 until `failures` attempts have failed.

    use GenServer

    def child_spec({test_pid, failures}) do
      %{
        id: __MODULE__,
        start: {__MODULE__, :start_link, [{test_pid, failures}]},
        restart: :temporary
      }
    end

    def start_link(args), do: GenServer.start_link(__MODULE__, args)

    @impl true
    def init({test_pid, failures}),
      do: {:ok, %{test_pid: test_pid, failures: failures, request_count: 0, next_sid: 200}}

    @impl true
    def handle_call({:request, request}, _from, state) do
      {body, state} = respond(request.topic, state)
      inbox = "_INBOX.placement-test.#{state.request_count}"
      send(request.recipient, {:msg, %{topic: inbox, body: Jason.encode!(body)}})
      send(state.test_pid, {:jetstream_request, request.topic})
      {:reply, {:ok, inbox}, %{state | request_count: state.request_count + 1}}
    end

    def handle_call({:unsub, sid, _opts}, _from, state) do
      send(state.test_pid, {:unsubscribed, sid})
      {:reply, :ok, state}
    end

    def handle_call({:sub, _subscriber, topic, _opts}, _from, state) do
      sid = state.next_sid
      send(state.test_pid, {:subscribed, sid, topic})
      {:reply, {:ok, sid}, %{state | next_sid: sid + 1}}
    end

    defp respond("$JS.API.STREAM.NAMES", state), do: {%{"streams" => []}, state}

    defp respond("$JS.API.STREAM.CREATE.mtr_results", %{failures: failures} = state)
         when failures > 0 do
      error = %{
        "code" => 400,
        "err_code" => 10_005,
        "description" => "no suitable peers for placement, insufficient storage"
      }

      {%{"error" => error}, %{state | failures: failures - 1}}
    end

    defp respond("$JS.API.STREAM.CREATE." <> _stream, state),
      do: {%{"type" => "io.nats.jetstream.api.v1.stream_create_response"}, state}

    defp respond(topic, state) do
      cond do
        String.contains?(topic, ".CONSUMER.INFO.") ->
          {%{"error" => %{"code" => 404, "description" => "consumer not found"}}, state}

        String.contains?(topic, ".CONSUMER.DURABLE.CREATE.") ->
          {%{"type" => "io.nats.jetstream.api.v1.consumer_create_response"}, state}

        String.contains?(topic, ".CONSUMER.DELETE.") ->
          {%{"type" => "io.nats.jetstream.api.v1.consumer_delete_response", "success" => true},
           state}

        true ->
          raise "unexpected JetStream request: #{topic}"
      end
    end
  end

  defmodule RecordingStreamHealth do
    @moduledoc false
    @behaviour ServiceRadar.EventWriter.StreamHealth

    @impl true
    def consumer_setup_failed(stream, reason, attempt) do
      send(:event_writer_stream_health_test, {:setup_failed, stream, reason, attempt})
      :ok
    end

    @impl true
    def consumer_setup_recovered(stream, attempts) do
      send(:event_writer_stream_health_test, {:setup_recovered, stream, attempts})
      :ok
    end
  end

  describe "a stream NATS cannot place" do
    setup do
      Process.register(self(), :event_writer_stream_health_test)

      metrics = %{name: "METRICS", stream_name: "metrics", subject: "metrics.>"}
      mtr = %{name: "MTR_RESULTS", stream_name: "mtr_results", subject: "mtr.results.>"}

      config = %Config{
        consumer_name: "serviceradar-event-writer",
        consumer_pull_batch_size: 64,
        streams: [metrics, mtr],
        retired_consumers: [%{stream_name: "events", consumer_name: "log-promotion"}]
      }

      %{config: config, metrics: metrics, mtr: mtr}
    end

    test "does not stop the consumers that did set up", %{config: config, mtr: mtr} do
      conn = start_supervised!({PlacementFailingConnection, {self(), 1}})

      capture_log(fn ->
        assert {:ok, context} = Producer.setup_jetstream_consumers(conn, config)
        assert [%{stream: "metrics", sid: 200}] = context.consumers
        assert [{^mtr, {"MTR_RESULTS", %{"err_code" => 10_005}}}] = context.failed_streams
      end)

      # Consumer subscriptions are integer sids; request inboxes are unsubscribed by topic.
      refute_received {:unsubscribed, 200}
      assert Process.alive?(conn)
      # The failing stream may be a retired consumer's replacement.
      refute_received {:jetstream_request, "$JS.API.CONSUMER.DELETE." <> _}
    end

    test "is retried on its own and joins the running consumers once it places",
         %{config: config, mtr: mtr} do
      # The earlier failed attempt is the hand-built entry below; this retry places.
      conn = start_supervised!({PlacementFailingConnection, {self(), 0}})
      state = producer_state(conn, config)

      entry = %{stream: mtr, attempt: 1, reason: :placement}

      state = %{
        state
        | failed_streams: %{"MTR_RESULTS" => entry},
          degraded_streams: %{"MTR_RESULTS" => 1}
      }

      {:noreply, [], state} =
        capture_log_result(fn ->
          Producer.handle_info({:retry_consumer, conn, "MTR_RESULTS"}, state)
        end)

      assert state.failed_streams == %{}
      assert state.degraded_streams == %{}
      assert Enum.map(state.consumer_context.consumers, & &1.stream) == ["metrics", "mtr_results"]
      assert MapSet.size(state.pull_subjects) == 2
      assert_received {:setup_recovered, "MTR_RESULTS", 1}
      refute_received {:unsubscribed, 200}
      # Every live consumer is up now, so the retired consumer is deleted.
      assert_received {:jetstream_request, "$JS.API.CONSUMER.DELETE.events.log-promotion"}
    end

    test "keeps retrying with a longer backoff while placement still fails",
         %{config: config, mtr: mtr} do
      conn = start_supervised!({PlacementFailingConnection, {self(), 5}})
      state = producer_state(conn, config)

      state = %{
        state
        | failed_streams: %{"MTR_RESULTS" => %{stream: mtr, attempt: 1, reason: :placement}},
          degraded_streams: %{"MTR_RESULTS" => 1}
      }

      {:noreply, [], state} =
        capture_log_result(fn ->
          Producer.handle_info({:retry_consumer, conn, "MTR_RESULTS"}, state)
        end)

      assert %{"MTR_RESULTS" => %{attempt: 2}} = state.failed_streams
      assert state.degraded_streams == %{"MTR_RESULTS" => 2}
      assert Enum.map(state.consumer_context.consumers, & &1.stream) == ["metrics"]
      assert_received {:setup_failed, "MTR_RESULTS", {"MTR_RESULTS", %{"err_code" => 10_005}}, 2}
    end

    test "ignores a retry scheduled for an earlier connection", %{config: config, mtr: mtr} do
      conn = start_supervised!({PlacementFailingConnection, {self(), 0}})
      state = producer_state(conn, config)

      state = %{
        state
        | failed_streams: %{"MTR_RESULTS" => %{stream: mtr, attempt: 1, reason: :placement}}
      }

      stale_conn = spawn(fn -> :ok end)

      assert {:noreply, [], ^state} =
               Producer.handle_info({:retry_consumer, stale_conn, "MTR_RESULTS"}, state)
    end
  end

  describe "stream health across reconnects" do
    setup do
      Process.register(self(), :event_writer_stream_health_test)

      config = %Config{
        consumer_name: "serviceradar-event-writer",
        streams: [%{name: "MTR_RESULTS", stream_name: "mtr_results", subject: "mtr.results.>"}]
      }

      mtr = hd(config.streams)

      state = %Producer{
        config: config,
        failed_streams: %{},
        degraded_streams: %{},
        setup_failures: 0
      }

      %{state: %{state | stream_health: RecordingStreamHealth}, mtr: mtr}
    end

    test "a stream degraded before a reconnect and set up after it recovers exactly once",
         %{state: state, mtr: mtr} do
      state = Producer.track_failed_streams(state, [{mtr, :placement}])
      assert_received {:setup_failed, "MTR_RESULTS", :placement, 1}
      assert state.degraded_streams == %{"MTR_RESULTS" => 1}

      # The connection drops and the reconnect sets every stream up.
      state = %{state | failed_streams: %{}}
      state = Producer.track_failed_streams(state, [])
      assert_received {:setup_recovered, "MTR_RESULTS", 1}
      assert state.degraded_streams == %{}

      state = Producer.track_failed_streams(state, [])
      refute_received {:setup_recovered, _stream, _attempts}
      assert state.degraded_streams == %{}
    end

    test "a stream failing before and after a reconnect is degraded once",
         %{state: state, mtr: mtr} do
      state = Producer.track_failed_streams(state, [{mtr, :placement}])
      state = %{state | failed_streams: %{}}
      state = Producer.track_failed_streams(state, [{mtr, :placement}])

      assert_received {:setup_failed, "MTR_RESULTS", :placement, 1}
      assert_received {:setup_failed, "MTR_RESULTS", :placement, 2}
      refute_received {:setup_recovered, _stream, _attempts}
      assert state.degraded_streams == %{"MTR_RESULTS" => 2}
    end

    test "a connect where no required consumer set up reports each stream and backs off",
         %{state: state, mtr: mtr} do
      error = {:consumer_setup_failed, [{mtr, :placement}]}

      state = Producer.record_connect_failure(state, error)
      assert_received {:setup_failed, "MTR_RESULTS", :placement, 1}
      assert state.degraded_streams == %{"MTR_RESULTS" => 1}
      assert state.setup_failures == 1
      assert Producer.reconnect_delay(error, state.setup_failures) == 5_000

      state = Producer.record_connect_failure(state, error)
      assert_received {:setup_failed, "MTR_RESULTS", :placement, 2}
      assert state.degraded_streams == %{"MTR_RESULTS" => 2}
      assert Producer.reconnect_delay(error, state.setup_failures) == 10_000

      assert Producer.reconnect_delay(error, 50) == 60_000
    end

    test "a transport failure backs off and reports no stream",
         %{state: state} do
      assert Producer.record_connect_failure(state, :econnrefused).setup_failures == 1
      assert Producer.reconnect_delay(:econnrefused, 7) == 60_000
      refute_received {:setup_failed, _stream, _reason, _attempt}
    end
  end

  test "retry backoff starts at 5 seconds and caps at 60" do
    assert Enum.map(1..6, &Producer.consumer_retry_delay/1) ==
             [5_000, 10_000, 20_000, 40_000, 60_000, 60_000]

    assert Producer.consumer_retry_delay(1_000) == 60_000
  end

  test "stream health reads the NATS error code from a setup failure" do
    alias ServiceRadar.EventWriter.StreamHealth

    assert StreamHealth.nats_error_code({"MTR_RESULTS", %{"err_code" => 10_005}}) == 10_005
    assert StreamHealth.nats_error_code(%{"err_code" => 10_005}) == 10_005
    assert StreamHealth.nats_error_code({:unexpected_stream, []}) == nil
  end

  # A producer connected with only METRICS up, as `handle_info(:connect)` leaves
  # it after a partial setup, without starting a real NATS connection.
  defp producer_state(conn, config) do
    metrics_only = %{config | streams: Enum.take(config.streams, 1), retired_consumers: []}
    {:ok, context} = Producer.setup_jetstream_consumers(conn, metrics_only)

    %Producer{
      config: config,
      conn: conn,
      consumer_context: context,
      connected: true,
      pull_subjects: context.pull_subjects,
      sid_to_pull_subject: context.sid_to_pull_subject,
      failed_streams: %{},
      degraded_streams: %{},
      setup_failures: 0,
      stream_health: RecordingStreamHealth
    }
  end

  defp capture_log_result(fun) do
    parent = self()
    capture_log(fn -> send(parent, {:captured_result, fun.()}) end)
    assert_received {:captured_result, result}
    result
  end
end
