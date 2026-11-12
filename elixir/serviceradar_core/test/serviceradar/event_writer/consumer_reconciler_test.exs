defmodule ServiceRadar.EventWriter.ConsumerReconcilerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ServiceRadar.EventWriter.Config
  alias ServiceRadar.EventWriter.ConsumerReconciler
  alias ServiceRadar.EventWriter.EdgeRecordStreamCutover

  @moduletag :db_free

  defmodule PlacementFailingConnection do
    @moduledoc false
    # A JetStream server with room for every stream except `mtr_results`, whose
    # creation is refused with err 10005 until `failures` attempts have failed.
    # Retired durables: `already-gone` is absent, `server-refuses` cannot be
    # deleted, any other is deleted.

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
      do: {:ok, %{test_pid: test_pid, failures: failures, request_count: 0}}

    @impl true
    def handle_call({:request, request}, _from, state) do
      {body, state} = respond(request.topic, state)
      inbox = "_INBOX.reconciler-test.#{state.request_count}"
      send(request.recipient, {:msg, %{topic: inbox, body: Jason.encode!(body)}})
      send(state.test_pid, {:jetstream_request, request.topic, request.body})
      {:reply, {:ok, inbox}, %{state | request_count: state.request_count + 1}}
    end

    def handle_call({:unsub, _sid, _opts}, _from, state), do: {:reply, :ok, state}

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

    defp respond("$JS.API.CONSUMER.DELETE.events.already-gone", state),
      do: {%{"error" => %{"code" => 404, "err_code" => 10_014}}, state}

    defp respond("$JS.API.CONSUMER.DELETE.events.server-refuses", state),
      do: {%{"error" => %{"code" => 500, "description" => "jetstream unavailable"}}, state}

    defp respond(topic, state) do
      cond do
        String.contains?(topic, ".CONSUMER.INFO.") ->
          {%{"error" => %{"code" => 404, "description" => "consumer not found"}}, state}

        String.contains?(topic, ".CONSUMER.DURABLE.CREATE.") ->
          {%{"type" => "io.nats.jetstream.api.v1.consumer_create_response"}, state}

        String.contains?(topic, ".CONSUMER.DELETE.") ->
          {%{"success" => true}, state}

        true ->
          raise "unexpected JetStream request: #{topic}"
      end
    end
  end

  defmodule EdgeCutoverServer do
    @moduledoc false
    # A JetStream server holding edge-record source streams in `limits`
    # retention with scripted consumer backlogs. DELETE removes the stream; a
    # later CREATE restores it with the created retention. CONSUMER.INFO
    # reports the scripted backlog while the stream and its durable exist.

    use GenServer

    def child_spec({test_pid, streams}) do
      %{
        id: __MODULE__,
        start: {__MODULE__, :start_link, [{test_pid, streams}]},
        restart: :temporary
      }
    end

    def start_link(args), do: GenServer.start_link(__MODULE__, args)

    @impl true
    def init({test_pid, streams}), do: {:ok, %{test_pid: test_pid, streams: streams}}

    @impl true
    def handle_call({:request, request}, _from, state) do
      {body, state} = respond(request.topic, request.body, state)
      inbox = "_INBOX.cutover-test.#{System.unique_integer([:positive])}"
      send(request.recipient, {:msg, %{topic: inbox, body: Jason.encode!(body)}})
      send(state.test_pid, {:jetstream_request, request.topic, request.body})
      {:reply, {:ok, inbox}, state}
    end

    def handle_call({:unsub, _sid, _opts}, _from, state), do: {:reply, :ok, state}

    defp respond("$JS.API.STREAM.NAMES", body, state) do
      %{"subject" => subject} = Jason.decode!(body)

      names =
        for {name, stream} <- state.streams,
            not stream.deleted and stream.subject == subject,
            do: name

      {%{"streams" => if(names == [], do: nil, else: names)}, state}
    end

    defp respond("$JS.API.STREAM.INFO." <> name, _body, state) do
      case Map.fetch!(state.streams, name) do
        %{deleted: true} ->
          {%{"error" => %{"code" => 404, "description" => "stream not found"}}, state}

        stream ->
          {%{
             "config" => %{
               "name" => name,
               "retention" => stream.retention,
               "sealed" => stream.sealed
             },
             "state" => %{"bytes" => stream.stored}
           }, state}
      end
    end

    defp respond("$JS.API.STREAM.UPDATE." <> name, body, state) do
      decoded = Jason.decode!(body)

      # Like JetStream, the fake refuses to reshape a sealed stream: only the
      # cutover unseals it. Updates on an unsealed stream apply normally.
      case Map.fetch!(state.streams, name) do
        %{sealed: true} ->
          {%{"error" => %{"code" => 400, "description" => "stream is sealed"}}, state}

        _stream ->
          streams = Map.update!(state.streams, name, &%{&1 | sealed: decoded["sealed"]})
          {%{"config" => decoded}, %{state | streams: streams}}
      end
    end

    defp respond("$JS.API.STREAM.DELETE." <> name, _body, state) do
      streams =
        Map.update!(state.streams, name, &%{&1 | deleted: true, consumer_exists: false})

      {%{"success" => true}, %{state | streams: streams}}
    end

    defp respond("$JS.API.STREAM.CREATE." <> name, body, state) do
      case Map.fetch!(state.streams, name) do
        %{create_error: message} when is_binary(message) ->
          {%{"error" => %{"description" => message}}, state}

        _stream ->
          %{"retention" => retention} = Jason.decode!(body)

          streams =
            Map.update!(state.streams, name, fn stream ->
              %{
                stream
                | deleted: false,
                  retention: retention,
                  sealed: false,
                  stored: 0,
                  consumer_exists: false
              }
            end)

          {%{"type" => "io.nats.jetstream.api.v1.stream_create_response"},
           %{state | streams: streams}}
      end
    end

    defp respond("$JS.API.CONSUMER.DURABLE.CREATE." <> rest, _body, state) do
      {name, _durable} = split_consumer(rest)
      streams = Map.update!(state.streams, name, &%{&1 | consumer_exists: true})

      {%{"type" => "io.nats.jetstream.api.v1.consumer_create_response"},
       %{state | streams: streams}}
    end

    defp respond("$JS.API.CONSUMER.INFO." <> rest, _body, state) do
      {name, _durable} = split_consumer(rest)

      case Map.fetch!(state.streams, name) do
        %{deleted: true} ->
          {%{"error" => %{"code" => 404, "description" => "consumer not found"}}, state}

        %{consumer_exists: false} ->
          {%{"error" => %{"code" => 404, "description" => "consumer not found"}}, state}

        stream ->
          {%{"num_pending" => stream.pending, "num_ack_pending" => 0}, state}
      end
    end

    defp respond(topic, _body, _state) do
      raise "unexpected JetStream request: #{topic}"
    end

    defp split_consumer(rest) do
      [stream_name, durable] = String.split(rest, ".", parts: 2)
      {stream_name, durable}
    end
  end

  defmodule RecordingStreamHealth do
    @moduledoc false
    @behaviour ServiceRadar.EventWriter.StreamHealth

    @impl true
    def consumer_setup_failed(stream, reason, attempt) do
      send(:event_writer_reconciler_test, {:setup_failed, stream, reason, attempt})
      :ok
    end

    @impl true
    def consumer_setup_recovered(stream, attempts) do
      send(:event_writer_reconciler_test, {:setup_recovered, stream, attempts})
      :ok
    end
  end

  setup do
    Process.register(self(), :event_writer_reconciler_test)

    metrics = %{name: "METRICS", stream_name: "metrics", subject: "metrics.>"}
    mtr = %{name: "MTR_RESULTS", stream_name: "mtr_results", subject: "mtr.results.>"}

    config = %Config{
      consumer_name: "serviceradar-event-writer",
      streams: [metrics, mtr],
      retired_consumers: [
        %{stream_name: "events", consumer_name: "log-promotion"},
        %{stream_name: "events", consumer_name: "already-gone"},
        %{stream_name: "events", consumer_name: "server-refuses"}
      ]
    }

    %{config: config}
  end

  test "a stream NATS cannot place does not hold back the others or delete a retired durable",
       %{config: config} do
    state = connected(start_supervised!({PlacementFailingConnection, {self(), 1}}), config)

    state = capture_log_result(fn -> ConsumerReconciler.ensure_all(state) end)

    assert Map.keys(state.failed) == ["MTR_RESULTS"]
    assert_received {:setup_failed, "MTR_RESULTS", %{"err_code" => 10_005}, 1}

    topics = topics()
    assert "$JS.API.CONSUMER.DURABLE.CREATE.metrics.serviceradar-event-writer-metrics" in topics
    # The failing stream may be a retired durable's replacement.
    refute Enum.any?(topics, &String.contains?(&1, ".CONSUMER.DELETE."))
  end

  test "the failed stream is retried alone and the retired durables go once all are up",
       %{config: config} do
    state = connected(start_supervised!({PlacementFailingConnection, {self(), 0}}), config)
    mtr = Enum.find(config.streams, &(&1.name == "MTR_RESULTS"))

    state = %{
      state
      | failed: %{"MTR_RESULTS" => %{stream: mtr, attempt: 1}},
        degraded: %{"MTR_RESULTS" => 1}
    }

    {{:noreply, state}, log} =
      with_log(fn ->
        ConsumerReconciler.handle_info({:retry_stream, state.conn, "MTR_RESULTS"}, state)
      end)

    assert state.failed == %{}
    assert state.degraded == %{}
    assert_received {:setup_recovered, "MTR_RESULTS", 1}

    topics = topics()
    refute Enum.any?(topics, &String.contains?(&1, ".CONSUMER.DURABLE.CREATE.metrics."))
    assert "$JS.API.CONSUMER.DELETE.events.log-promotion" in topics
    assert "$JS.API.CONSUMER.DELETE.events.already-gone" in topics
    assert "$JS.API.CONSUMER.DELETE.events.server-refuses" in topics

    # An absent durable is already retired; only the refused delete is a warning.
    assert log =~ "could not delete retired JetStream consumer events/server-refuses"
    refute log =~ "events/already-gone"
  end

  test "a retry scheduled for an earlier connection is ignored", %{config: config} do
    state = connected(start_supervised!({PlacementFailingConnection, {self(), 0}}), config)
    mtr = Enum.find(config.streams, &(&1.name == "MTR_RESULTS"))
    state = %{state | failed: %{"MTR_RESULTS" => %{stream: mtr, attempt: 1}}}
    stale_conn = spawn(fn -> :ok end)

    assert {:noreply, ^state} =
             ConsumerReconciler.handle_info({:retry_stream, stale_conn, "MTR_RESULTS"}, state)

    assert topics() == []
  end

  test "the edge-retention tick reschedules itself while disconnected without touching NATS",
       %{config: config} do
    config = %{
      config
      | streams: [Config.edge_record_stream(), Config.edge_record_audit_stream()],
        ownership_reconcile_interval_ms: 20
    }

    state = %ConsumerReconciler{config: config, connected: false}

    assert {:noreply, ^state} =
             ConsumerReconciler.handle_info(:edge_retention_reconcile, state)

    assert_receive :edge_retention_reconcile, 1_000
    assert topics() == []
  end

  # One process holds at most one global cutover lock: OTP logs
  # "registered under several names" and refuses the second registration,
  # which the reconciler would misread as "another core holds it". While this
  # core drains one stream, the other stream waits for the next tick.
  test "a second stream cutover waits while this core holds a cutover lock",
       %{config: config} do
    {bulk_name, audit_name, state} = cutover_state(config, 5)

    {{:noreply, state}, log} =
      with_log(fn -> ConsumerReconciler.handle_info(:edge_retention_reconcile, state) end)

    assert Map.keys(state.edge_cutovers) == [bulk_name]
    assert :global.whereis_name({EdgeRecordStreamCutover, bulk_name}) == self()
    assert :global.whereis_name({EdgeRecordStreamCutover, audit_name}) == :undefined
    refute log =~ "registered under several names"

    assert [{"$JS.API.STREAM.UPDATE." <> ^bulk_name, body}] =
             for({"$JS.API.STREAM.UPDATE." <> _, _} = request <- requests(), do: request)

    assert Jason.decode!(body)["sealed"] == true
    refute Enum.any?(topics(), &String.starts_with?(&1, "$JS.API.STREAM.DELETE."))
    refute Enum.any?(topics(), &String.contains?(&1, ".CONSUMER."))

    on_exit(fn -> :global.unregister_name({EdgeRecordStreamCutover, bulk_name}) end)
  end

  # The wait is not a stall: once the first stream cuts over and releases its
  # lock, the next tick starts the waiting stream, which then cuts over too.
  test "a waiting stream cutover starts once the first stream cuts over",
       %{config: config} do
    {bulk_name, audit_name, state} = cutover_state(config, 0)

    {{:noreply, state}, log1} =
      with_log(fn -> ConsumerReconciler.handle_info(:edge_retention_reconcile, state) end)

    assert Map.keys(state.edge_cutovers) == [bulk_name]

    {{:noreply, state}, _log2} =
      with_log(fn ->
        ConsumerReconciler.handle_info({:edge_cutover_poll, state.conn, bulk_name}, state)
      end)

    assert state.edge_cutovers == %{}
    assert :global.whereis_name({EdgeRecordStreamCutover, bulk_name}) == :undefined

    {{:noreply, state}, log3} =
      with_log(fn -> ConsumerReconciler.handle_info(:edge_retention_reconcile, state) end)

    assert Map.keys(state.edge_cutovers) == [audit_name]
    assert :global.whereis_name({EdgeRecordStreamCutover, audit_name}) == self()

    {{:noreply, state}, _log4} =
      with_log(fn ->
        ConsumerReconciler.handle_info({:edge_cutover_poll, state.conn, audit_name}, state)
      end)

    assert state.edge_cutovers == %{}
    assert :global.whereis_name({EdgeRecordStreamCutover, audit_name}) == :undefined

    refute log1 <> log3 =~ "registered under several names"

    deletes =
      for {"$JS.API.STREAM.DELETE." <> name, _} <- requests(), do: name

    assert Enum.sort(deletes) == Enum.sort([bulk_name, audit_name])
  end

  # A sealed stream is mid-cutover: its shape belongs to the cutover, so
  # ensure must not reshape it (JetStream refuses the update) and must not
  # report the stream as failed. The durable is still set up, and the cutover
  # finishes the conversion on its next pass.
  test "ensure on a sealed stream skips the shape update and still sets up the durable",
       %{config: config} do
    bulk = Config.edge_record_stream()
    bulk_name = Config.jetstream_stream_name(bulk)

    servers = %{
      bulk_name => %{
        subject: bulk.subject,
        retention: "limits",
        sealed: true,
        stored: 1_024,
        deleted: false,
        pending: 0,
        consumer_exists: false,
        create_error: "stream name is already in use"
      }
    }

    conn = start_supervised!({EdgeCutoverServer, {self(), servers}})

    config = %{
      config
      | consumer_name: "cutover-test-writer",
        streams: [bulk],
        retired_consumers: []
    }

    log = capture_log(fn -> assert :ok = ConsumerReconciler.ensure_stream(conn, config, bulk) end)

    refute log =~ "Failed to initialize"

    reqs = requests()

    assert Enum.empty?(for {"$JS.API.STREAM.UPDATE." <> _, _} <- reqs, do: :update)

    refute Enum.any?(reqs, fn {topic, _} ->
             String.starts_with?(topic, "$JS.API.STREAM.DELETE.")
           end)

    assert Enum.any?(reqs, fn {topic, _} ->
             String.starts_with?(topic, "$JS.API.CONSUMER.DURABLE.CREATE.#{bulk_name}.")
           end)
  end

  defp cutover_state(config, pending) do
    streams = [Config.edge_record_stream(), Config.edge_record_audit_stream()]
    bulk_name = Config.jetstream_stream_name(hd(streams))
    audit_name = Config.jetstream_stream_name(hd(tl(streams)))

    servers =
      Map.new(streams, fn stream ->
        {Config.jetstream_stream_name(stream),
         %{
           subject: stream.subject,
           retention: "limits",
           sealed: false,
           stored: 1_024,
           deleted: false,
           pending: pending,
           consumer_exists: true,
           create_error: nil
         }}
      end)

    conn = start_supervised!({EdgeCutoverServer, {self(), servers}})

    config = %{
      config
      | consumer_name: "cutover-test-writer",
        streams: streams,
        retired_consumers: [],
        ownership_reconcile_interval_ms: 20
    }

    state = %ConsumerReconciler{
      config: config,
      conn: conn,
      monitor: make_ref(),
      connected: true,
      stream_health: RecordingStreamHealth,
      owned_streams: %{}
    }

    {bulk_name, audit_name, state}
  end

  # One health event per transition for the whole deployment, however many
  # reconnects it takes: the reconciler is the only reporter.
  test "a stream degraded across a reconnect is reported degraded once and recovered once",
       %{config: config} do
    conn = start_supervised!({PlacementFailingConnection, {self(), 2}})
    state = capture_log_result(fn -> ConsumerReconciler.ensure_all(connected(conn, config)) end)
    assert_received {:setup_failed, "MTR_RESULTS", _reason, 1}

    # The connection drops; the reconnect sets every stream up again.
    {:noreply, state} =
      capture_log_result(fn ->
        ConsumerReconciler.handle_info({:DOWN, state.monitor, :process, conn, :closed}, state)
      end)

    assert state.failed == %{}
    assert state.degraded == %{"MTR_RESULTS" => 1}
    state = %{state | conn: conn, connected: true}

    state = capture_log_result(fn -> ConsumerReconciler.ensure_all(state) end)
    assert_received {:setup_failed, "MTR_RESULTS", _reason, 2}
    refute_received {:setup_recovered, _, _}

    state = capture_log_result(fn -> ConsumerReconciler.ensure_all(%{state | failed: %{}}) end)
    assert_received {:setup_recovered, "MTR_RESULTS", 2}
    assert state.degraded == %{}

    capture_log_result(fn -> ConsumerReconciler.ensure_all(state) end)
    refute_received {:setup_recovered, _, _}
  end

  # Every worker replica gets the in-flight budget one EventWriter had, so the
  # shared durable's ceiling is that times the pipelines bound to it.
  test "a shared durable's max_ack_pending covers every worker and a coordinator stream's one" do
    conn = start_supervised!({PlacementFailingConnection, {self(), 0}})

    predictions = %{
      name: "ANALYTICS_PREDICTIONS",
      stream_name: "analytics_predictions",
      subject: "signals.analytics.predictions.>"
    }

    metrics = %{name: "METRICS", stream_name: "metrics", subject: "metrics.>"}

    flows = %{
      name: "NETFLOW_RAW",
      stream_name: "flows",
      subject: "flows.raw.netflow",
      consumer_max_ack_pending: 1024
    }

    config = %Config{
      consumer_name: "serviceradar-event-writer",
      max_ack_pending: 256,
      workers: 3,
      streams: [predictions, metrics, flows]
    }

    for stream <- config.streams,
        do: assert(:ok = ConsumerReconciler.ensure_stream(conn, config, stream))

    assert created_max_ack_pending() == %{
             "serviceradar-event-writer-analytics-predictions" => 256,
             "serviceradar-event-writer-metrics" => 768,
             "serviceradar-event-writer-netflow-raw" => 3072
           }
  end

  defp connected(conn, config) do
    %ConsumerReconciler{
      config: config,
      conn: conn,
      monitor: make_ref(),
      connected: true,
      stream_health: RecordingStreamHealth,
      owned_streams: %{}
    }
  end

  defp created_max_ack_pending do
    for {"$JS.API.CONSUMER.DURABLE.CREATE." <> _, body} <- requests(), into: %{} do
      %{"config" => config} = Jason.decode!(body)
      {config["durable_name"], config["max_ack_pending"]}
    end
  end

  defp topics, do: Enum.map(requests(), &elem(&1, 0))

  defp requests(acc \\ []) do
    receive do
      {:jetstream_request, topic, body} -> requests([{topic, body} | acc])
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
