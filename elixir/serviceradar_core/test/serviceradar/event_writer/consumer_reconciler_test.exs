defmodule ServiceRadar.EventWriter.ConsumerReconcilerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ServiceRadar.EventWriter.Config
  alias ServiceRadar.EventWriter.ConsumerReconciler

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
