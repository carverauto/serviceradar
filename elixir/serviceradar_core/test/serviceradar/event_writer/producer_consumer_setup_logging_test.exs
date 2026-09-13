defmodule ServiceRadar.EventWriter.ProducerConsumerSetupLoggingTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ServiceRadar.EventWriter.Config
  alias ServiceRadar.EventWriter.Producer

  @moduletag :db_free

  @netflow_inbox_prefix "_INBOX.serviceradar.event_writer.pull.serviceradar-event-writer.netflow_raw."

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

    # Every durable the reconciler would create already exists. A worker only
    # reads the server, so any other request is a test failure.
    defp response_for("$JS.API.CONSUMER.INFO." <> rest) do
      durable = rest |> String.split(".") |> List.last()
      %{"config" => %{"durable_name" => durable, "filter_subject" => "flows.raw.netflow"}}
    end

    defp response_for(topic), do: raise("unexpected JetStream request: #{topic}")
  end

  test "a refused NATS connection leaves the producer alive and retrying" do
    # Bind an ephemeral port and release it: nothing listens there, so the
    # connect below is refused immediately rather than timing out.
    {:ok, listener} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(listener)
    :ok = :gen_tcp.close(listener)

    config = %Config{
      enabled: true,
      nats: %{
        host: "127.0.0.1",
        port: port,
        user: nil,
        password: nil,
        tls: false,
        jwt: nil,
        nkey_seed: nil,
        creds_file: nil
      },
      consumer_name: "serviceradar-event-writer",
      producer_name: nil,
      streams: [],
      consumer_pull_batch_size: 64,
      max_ack_pending: 8
    }

    log =
      capture_log(fn ->
        pid = start_supervised!({Producer, config})
        ref = Process.monitor(pid)

        # init/1 queues :connect ahead of this call, so once it returns the
        # refused connect has been handled. A producer that still linked the
        # connection would have exited with :econnrefused here instead.
        assert %GenStage{state: %Producer{connected: false, conn: nil}} = :sys.get_state(pid)
        refute_received {:DOWN, ^ref, :process, ^pid, _}
        assert Process.alive?(pid)
      end)

    assert log =~ "EventWriter NATS connection failed: :econnrefused, retrying"
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

    {pull_subject, log} =
      with_log([level: :debug], fn ->
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
                      pull_subject: pull_subject,
                      pull_batch_size: 64
                    }
                  ],
                  pull_subjects: pull_subjects,
                  sid_to_pull_subject: sid_to_pull_subject
                }} = Producer.setup_jetstream_consumers(conn, config)

        assert pull_subjects == MapSet.new([pull_subject])
        assert sid_to_pull_subject == %{99 => pull_subject}
        pull_subject
      end)

    assert String.starts_with?(pull_subject, @netflow_inbox_prefix)

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
    refute log =~ "could not bind durable consumer"
    assert Process.alive?(conn)

    # Both binds only resolve the stream and read the durable.
    durable_info = "$JS.API.CONSUMER.INFO.flows.serviceradar-event-writer-netflow-raw"

    assert drain_requests() == [
             "$JS.API.STREAM.NAMES",
             durable_info,
             "$JS.API.STREAM.NAMES",
             durable_info
           ]

    assert_receive {:subscribed, 99, ^pull_subject}
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

    failure_reason =
      {"NETFLOW_RAW_REQUIRED", {:unexpected_stream, expected: "events", resolved: "flows"}}

    {pull_subject, log} =
      with_log([level: :debug], fn ->
        assert {:ok,
                %{
                  consumers: [%{sid: 99, pull_subject: pull_subject}],
                  failed_streams: [{^required_stream, ^failure_reason}]
                }} = Producer.setup_jetstream_consumers(conn, config)

        pull_subject
      end)

    assert String.starts_with?(pull_subject, @netflow_inbox_prefix)

    assert log =~ "[error]"
    assert log =~ "EventWriter could not bind durable consumer"
    assert log =~ ~s(name="NETFLOW_RAW_REQUIRED")
    assert log =~ ~s(durable="serviceradar-event-writer-netflow-raw-required")
    assert log =~ ~s(stream="events")
    assert log =~ ~s(filter_subject="flows.raw.netflow")
    assert log =~ ~s(expected: "events")
    assert log =~ ~s(resolved: "flows")
    assert length(Regex.scan(~r/EventWriter could not bind durable consumer/, log)) == 1

    refute log =~ "skipping best-effort drain consumer"

    assert_receive {:subscribed, 99, ^pull_subject}
    refute_received {:unsubscribed, 99}
    assert Process.alive?(conn)
  end

  # JetStream gives each pulled message to one pull request but publishes it
  # on that request's reply subject, which core NATS fans out to every
  # subscriber. Two EventWriter instances on one durable must therefore never
  # listen on the same inbox, or each processes every batch the other pulled.
  test "EventWriter instances bound to the same durable pull into distinct inboxes" do
    config = %Config{
      consumer_name: "serviceradar-event-writer",
      consumer_pull_batch_size: 64,
      streams: [%{name: "NETFLOW_RAW", stream_name: "flows", subject: "flows.raw.netflow"}]
    }

    conn = start_supervised!({FakeJetStreamConnection, self()})

    inbox = fn ->
      assert {:ok,
              %{
                consumers: [
                  %{durable: "serviceradar-event-writer-netflow-raw", pull_subject: subject}
                ]
              }} = Producer.setup_jetstream_consumers(conn, config)

      subject
    end

    first = inbox.()
    second = inbox.()

    assert first != second
    assert_receive {:subscribed, _sid, ^first}
    assert_receive {:subscribed, _sid, ^second}
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

  defmodule DurableNotReadyConnection do
    @moduledoc false
    # A JetStream server where the METRICS durable exists and the MTR_RESULTS
    # durable appears only after `misses` reads, as when the coordinator's
    # reconciler has not created it yet.

    use GenServer

    def child_spec({test_pid, misses}) do
      %{
        id: __MODULE__,
        start: {__MODULE__, :start_link, [{test_pid, misses}]},
        restart: :temporary
      }
    end

    def start_link(args), do: GenServer.start_link(__MODULE__, args)

    @impl true
    def init({test_pid, misses}),
      do: {:ok, %{test_pid: test_pid, misses: misses, request_count: 0, next_sid: 200}}

    @impl true
    def handle_call({:request, request}, _from, state) do
      {body, state} = respond(request.topic, state)
      inbox = "_INBOX.durable-test.#{state.request_count}"
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

    defp respond("$JS.API.CONSUMER.INFO.metrics." <> durable, state),
      do: {durable_info(durable, "metrics.>"), state}

    defp respond("$JS.API.CONSUMER.INFO.mtr_results." <> _durable, %{misses: misses} = state)
         when misses > 0 do
      {%{
         "error" => %{"code" => 404, "err_code" => 10_014, "description" => "consumer not found"}
       }, %{state | misses: misses - 1}}
    end

    defp respond("$JS.API.CONSUMER.INFO.mtr_results." <> durable, state),
      do: {durable_info(durable, "mtr.results.>"), state}

    defp respond(topic, _state), do: raise("unexpected JetStream request: #{topic}")

    defp durable_info(durable, filter),
      do: %{"config" => %{"durable_name" => durable, "filter_subject" => filter}}
  end

  describe "a durable that does not exist yet" do
    setup do
      test_pid = self()
      handler = "producer-bind-#{System.unique_integer([:positive])}"

      :telemetry.attach_many(
        handler,
        [
          [:serviceradar, :event_writer, :consumer_bind, :failed],
          [:serviceradar, :event_writer, :consumer_bind, :recovered]
        ],
        fn event, measurements, metadata, _ ->
          send(test_pid, {List.last(event), metadata.stream, measurements})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      metrics = %{name: "METRICS", stream_name: "metrics", subject: "metrics.>"}
      mtr = %{name: "MTR_RESULTS", stream_name: "mtr_results", subject: "mtr.results.>"}

      config = %Config{
        consumer_name: "serviceradar-event-writer",
        consumer_pull_batch_size: 64,
        streams: [metrics, mtr],
        retired_consumers: [%{stream_name: "events", consumer_name: "log-promotion"}]
      }

      %{config: config, mtr: mtr}
    end

    test "does not stop the consumers that did bind", %{config: config, mtr: mtr} do
      conn = start_supervised!({DurableNotReadyConnection, {self(), 1}})

      capture_log(fn ->
        assert {:ok, context} = Producer.setup_jetstream_consumers(conn, config)
        assert [%{stream: "metrics", sid: 200}] = context.consumers

        assert [{^mtr, {"MTR_RESULTS", {:durable_not_ready, "mtr_results"}}}] =
                 context.failed_streams
      end)

      # Consumer subscriptions are integer sids; request inboxes are unsubscribed by topic.
      refute_received {:unsubscribed, 200}
      assert Process.alive?(conn)
    end

    test "is retried on its own and joins the running consumers once it exists",
         %{config: config, mtr: mtr} do
      conn = start_supervised!({DurableNotReadyConnection, {self(), 0}})
      state = producer_state(conn, config)

      state = %{
        state
        | failed_streams: %{"MTR_RESULTS" => %{stream: mtr, attempt: 1, reason: :not_ready}},
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
      assert_received {:recovered, "MTR_RESULTS", %{attempts: 1}}
      refute_received {:unsubscribed, 200}
    end

    test "keeps retrying with a longer backoff while the durable is missing",
         %{config: config, mtr: mtr} do
      conn = start_supervised!({DurableNotReadyConnection, {self(), 5}})
      state = producer_state(conn, config)

      state = %{
        state
        | failed_streams: %{"MTR_RESULTS" => %{stream: mtr, attempt: 1, reason: :not_ready}},
          degraded_streams: %{"MTR_RESULTS" => 1}
      }

      {:noreply, [], state} =
        capture_log_result(fn ->
          Producer.handle_info({:retry_consumer, conn, "MTR_RESULTS"}, state)
        end)

      assert %{"MTR_RESULTS" => %{attempt: 2}} = state.failed_streams
      assert state.degraded_streams == %{"MTR_RESULTS" => 2}
      assert Enum.map(state.consumer_context.consumers, & &1.stream) == ["metrics"]
      assert_received {:failed, "MTR_RESULTS", %{attempt: 2}}
    end

    test "ignores a retry scheduled for an earlier connection", %{config: config, mtr: mtr} do
      conn = start_supervised!({DurableNotReadyConnection, {self(), 0}})
      state = producer_state(conn, config)

      state = %{
        state
        | failed_streams: %{"MTR_RESULTS" => %{stream: mtr, attempt: 1, reason: :not_ready}}
      }

      stale_conn = spawn(fn -> :ok end)

      assert {:noreply, [], ^state} =
               Producer.handle_info({:retry_consumer, stale_conn, "MTR_RESULTS"}, state)
    end

    test "a connect where no required consumer bound backs off", %{mtr: mtr} do
      error = {:consumer_setup_failed, [{mtr, :not_ready}]}
      state = %Producer{failed_streams: %{}, degraded_streams: %{}, setup_failures: 0}

      state = Producer.record_connect_failure(state, error)
      assert state.setup_failures == 1
      assert Producer.reconnect_delay(error, state.setup_failures) == 5_000

      state = Producer.record_connect_failure(state, error)
      assert state.degraded_streams == %{"MTR_RESULTS" => 2}
      assert Producer.reconnect_delay(error, state.setup_failures) == 10_000
      assert Producer.reconnect_delay(:econnrefused, 50) == 60_000
    end
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
    metrics_only = %{config | streams: Enum.take(config.streams, 1)}
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
      setup_failures: 0
    }
  end

  defp drain_requests(acc \\ []) do
    receive do
      {:jetstream_request, topic} -> drain_requests([topic | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp capture_log_result(fun) do
    parent = self()
    capture_log(fn -> send(parent, {:captured_result, fun.()}) end)
    assert_received {:captured_result, result}
    result
  end
end
