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

  test "required setup failures log an error and reject the partial pipeline" do
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
        assert {:error, {:consumer_setup_failed, [^failure_reason]}} =
                 Producer.setup_jetstream_consumers(conn, config)
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
    assert_receive {:unsubscribed, 99}
    refute_received {:subscribed, 100, _topic}
    refute Process.alive?(conn)
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
end
