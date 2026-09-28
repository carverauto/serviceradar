defmodule ServiceRadar.EventWriter.StreamOwnershipTest do
  @moduledoc """
  EventWriter's side of the `serviceradar.owner` stream claim (design D6 of
  `update-jetstream-storage-budget`): the claim decision, the ownership
  reconcile tick, stream creation at consumer setup, and the producer timer.

  JetStream is a fake Gnat connection holding stream configs in memory, so no
  broker is needed. Stream names, subjects and sizes are synthetic.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Gnat.Jetstream.API.Util
  alias ServiceRadar.EventWriter.Config
  alias ServiceRadar.EventWriter.Producer
  alias ServiceRadar.EventWriter.StreamOwnership

  require Logger

  @moduletag :db_free

  @gib 1_073_741_824
  @minute 60_000
  @grace 15 * @minute

  @collectors %{
    "events" => "otel-log-collector",
    "flows" => "flow-collector",
    "ARANCINI_CAUSAL" => "bmp-collector"
  }

  defmodule FakeNats do
    @moduledoc false
    # A Gnat connection stand-in: answers the JetStream API requests EventWriter
    # makes from an in-memory map of streams, and reports every request, every
    # subscription and every consumer unsubscribe to the test process.

    use GenServer

    def start_link({test_pid, streams}), do: GenServer.start_link(__MODULE__, {test_pid, streams})

    def child_spec(arg) do
      %{id: __MODULE__, start: {__MODULE__, :start_link, [arg]}, restart: :temporary}
    end

    def stream(conn, name), do: GenServer.call(conn, {:get_stream, name})
    def put_stream(conn, name, entry), do: GenServer.call(conn, {:put_stream, name, entry})

    # `hook.(info_count, entry)` runs before the Nth STREAM.INFO of `name` is
    # answered and returns the entry to store and answer with.
    def on_info(conn, name, hook), do: GenServer.call(conn, {:on_info, name, hook})

    @impl true
    def init({test_pid, streams}) do
      {:ok, %{test_pid: test_pid, streams: streams, infos: %{}, hooks: %{}, next_sid: 1}}
    end

    @impl true
    def handle_call({:request, request}, _from, state) do
      %{recipient: recipient, topic: topic, body: body} = request
      send(state.test_pid, {:js, topic, body})
      {reply, state} = respond(topic, body, state)
      inbox = "_INBOX.fake.#{System.unique_integer([:positive])}"
      send(recipient, {:msg, %{topic: inbox, body: Jason.encode!(reply)}})
      {:reply, {:ok, inbox}, state}
    end

    def handle_call({:unsub, sid, _opts}, _from, state) do
      # Every Gnat.request unsubscribes its reply inbox (a binary); only an
      # integer sid is a consumer subscription.
      if is_integer(sid), do: send(state.test_pid, {:unsubscribed, sid})
      {:reply, :ok, state}
    end

    def handle_call({:sub, _subscriber, topic, _opts}, _from, state) do
      sid = state.next_sid
      send(state.test_pid, {:subscribed, sid, topic})
      {:reply, {:ok, sid}, %{state | next_sid: sid + 1}}
    end

    def handle_call({:get_stream, name}, _from, state),
      do: {:reply, Map.get(state.streams, name), state}

    def handle_call({:put_stream, name, entry}, _from, state),
      do: {:reply, :ok, put_in(state, [:streams, name], entry)}

    def handle_call({:on_info, name, hook}, _from, state),
      do: {:reply, :ok, put_in(state, [:hooks, name], hook)}

    defp respond("$JS.API.STREAM.NAMES", body, state) do
      %{"subject" => subject} = Jason.decode!(body)

      names =
        for {name, %{"config" => config}} <- state.streams,
            Enum.any?(config["subjects"], &Config.nats_filter_covers?(&1, subject)),
            do: name

      {%{"streams" => names}, state}
    end

    defp respond("$JS.API.STREAM.INFO." <> name, _body, state) do
      count = Map.get(state.infos, name, 0) + 1
      state = put_in(state, [:infos, name], count)

      state =
        case {Map.fetch(state.hooks, name), Map.fetch(state.streams, name)} do
          {{:ok, hook}, {:ok, entry}} -> put_in(state, [:streams, name], hook.(count, entry))
          _ -> state
        end

      case Map.fetch(state.streams, name) do
        {:ok, %{"config" => config, "bytes" => bytes}} ->
          {%{"config" => config, "state" => %{"bytes" => bytes}}, state}

        :error ->
          {not_found(), state}
      end
    end

    defp respond("$JS.API.STREAM.CREATE." <> name, body, state) do
      if Map.has_key?(state.streams, name) do
        {%{"error" => %{"code" => 400, "description" => "stream name already in use"}}, state}
      else
        config = Jason.decode!(body)
        entry = %{"config" => config, "bytes" => 0}
        {%{"config" => config}, put_in(state, [:streams, name], entry)}
      end
    end

    defp respond("$JS.API.STREAM.UPDATE." <> name, body, state) do
      config = Jason.decode!(body)
      %{"bytes" => bytes} = Map.fetch!(state.streams, name)
      # Discard-old: a lower max_bytes evicts the oldest messages to fit.
      bytes = evict(bytes, config["max_bytes"])
      entry = %{"config" => config, "bytes" => bytes}
      {%{"config" => config}, put_in(state, [:streams, name], entry)}
    end

    defp respond("$JS.API.CONSUMER.INFO." <> _rest, _body, state) do
      {%{"error" => %{"code" => 404, "description" => "consumer not found"}}, state}
    end

    defp respond("$JS.API.CONSUMER.DURABLE.CREATE." <> _rest, _body, state) do
      {%{"type" => "io.nats.jetstream.api.v1.consumer_create_response"}, state}
    end

    defp not_found do
      %{"error" => %{"code" => 404, "err_code" => 10_059, "description" => "stream not found"}}
    end

    defp evict(bytes, max_bytes) when is_integer(max_bytes) and max_bytes > 0,
      do: min(bytes, max_bytes)

    defp evict(bytes, _max_bytes), do: bytes
  end

  setup do
    # The reconcile before/after lines are :info; mix test runs at :warning.
    Logger.put_process_level(self(), :info)
    clock = :atomics.new(1, signed: true)
    {:ok, clock: clock, watched: watched_streams()}
  end

  describe "decide/3" do
    test "reconciles a stream claimed by event-writer", %{clock: clock} do
      for name <- StreamOwnership.multi_owner_streams() do
        {decision, _tracker} =
          StreamOwnership.decide(tracker(clock), name, config(name, owner: "event-writer"))

        assert decision == :reconcile, name
        assert StreamOwnership.reconciles_shape?(decision)
      end
    end

    test "never reconciles a collector-claimed stream, however long it is watched",
         %{clock: clock} do
      for name <- StreamOwnership.multi_owner_streams() do
        claimed = config(name, owner: Map.fetch!(@collectors, name))
        tracker = tracker(clock)

        tracker =
          Enum.reduce([0, @grace, 4 * @grace], tracker, fn at, acc ->
            set_clock(clock, at)
            {decision, acc} = StreamOwnership.decide(acc, name, claimed)
            assert decision == :merge_subjects, "#{name} at #{at} ms"
            refute StreamOwnership.reconciles_shape?(decision)
            acc
          end)

        assert tracker.unclaimed_since == %{}
      end
    end

    test "an unclaimed stream is claimed only after the grace period", %{clock: clock} do
      for name <- StreamOwnership.multi_owner_streams() do
        legacy = config(name)
        set_clock(clock, 0)

        {decision, tracker} = StreamOwnership.decide(tracker(clock), name, legacy)
        assert decision == :await_grace, name
        refute StreamOwnership.reconciles_shape?(decision)

        set_clock(clock, @grace - 1)
        {decision, tracker} = StreamOwnership.decide(tracker, name, legacy)
        assert decision == :await_grace, name
        refute StreamOwnership.reconciles_shape?(decision)

        set_clock(clock, @grace)
        {decision, _tracker} = StreamOwnership.decide(tracker, name, legacy)
        assert decision == :claim, name
        assert StreamOwnership.reconciles_shape?(decision)
      end
    end

    test "a restart resets the grace clock", %{clock: clock} do
      for name <- StreamOwnership.multi_owner_streams() do
        legacy = config(name)
        set_clock(clock, 0)
        {:await_grace, _before_restart} = StreamOwnership.decide(tracker(clock), name, legacy)

        # Ten minutes later the process restarts: its tracker starts empty.
        set_clock(clock, 10 * @minute)
        {decision, restarted} = StreamOwnership.decide(tracker(clock), name, legacy)
        assert decision == :await_grace, name

        # 15 minutes after the first observation, but not after the restart.
        set_clock(clock, @grace)
        {decision, restarted} = StreamOwnership.decide(restarted, name, legacy)
        assert decision == :await_grace, name

        set_clock(clock, 10 * @minute + @grace)
        {decision, _restarted} = StreamOwnership.decide(restarted, name, legacy)
        assert decision == :claim, name
      end
    end

    test "a removed claim starts the grace period from when it is first seen gone",
         %{clock: clock} do
      name = "ARANCINI_CAUSAL"
      set_clock(clock, 0)

      {:merge_subjects, tracker} =
        StreamOwnership.decide(tracker(clock), name, config(name, owner: "bmp-collector"))

      set_clock(clock, 2 * @grace)
      {decision, tracker} = StreamOwnership.decide(tracker, name, config(name))
      assert decision == :await_grace

      set_clock(clock, 3 * @grace)
      assert {:claim, _tracker} = StreamOwnership.decide(tracker, name, config(name))
    end
  end

  describe "ownership reconcile tick" do
    test "a legacy 10 GiB flows stream with no collector converges after the grace period",
         %{clock: clock, watched: watched} do
      conn = start_nats(%{"flows" => entry(config("flows", max_bytes: 10 * @gib), 9 * @gib)})
      request = request(conn)
      set_clock(clock, 0)

      tracker = StreamOwnership.reconcile(tracker(clock), request, watched)
      assert_shape(conn, "flows", 10 * @gib, nil)

      set_clock(clock, @grace - 1)
      tracker = StreamOwnership.reconcile(tracker, request, watched)
      assert_shape(conn, "flows", 10 * @gib, nil)
      assert FakeNats.stream(conn, "flows")["bytes"] == 9 * @gib

      set_clock(clock, @grace)

      log =
        capture_log(fn ->
          _tracker = StreamOwnership.reconcile(tracker, request, watched)
        end)

      assert_shape(conn, "flows", @gib, "event-writer")
      assert FakeNats.stream(conn, "flows")["config"]["num_replicas"] == 1
      assert FakeNats.stream(conn, "flows")["bytes"] == @gib
      assert log =~ "max_bytes #{10 * @gib} -> #{@gib}"
      assert log =~ "serviceradar.owner unset -> \"event-writer\""
      assert log =~ "evicts the oldest messages"
    end

    test "a collector that claims inside the grace period is never overridden",
         %{clock: clock, watched: watched} do
      conn = start_nats(%{"flows" => entry(config("flows", max_bytes: 10 * @gib), 9 * @gib)})
      request = request(conn)
      set_clock(clock, 0)
      tracker = StreamOwnership.reconcile(tracker(clock), request, watched)

      # flow-collector starts and claims the stream, growing it to 8 GiB R3.
      set_clock(clock, 5 * @minute)

      collector = config("flows", owner: "flow-collector", max_bytes: 8 * @gib, replicas: 3)
      FakeNats.put_stream(conn, "flows", entry(collector, 8 * @gib))

      for at <- [@grace, 2 * @grace, 10 * @grace], reduce: tracker do
        acc ->
          set_clock(clock, at)
          StreamOwnership.reconcile(acc, request, watched)
      end

      assert_shape(conn, "flows", 8 * @gib, "flow-collector")
      assert FakeNats.stream(conn, "flows")["config"]["num_replicas"] == 3
      assert FakeNats.stream(conn, "flows")["bytes"] == 8 * @gib
      refute_received {:js, "$JS.API.STREAM.UPDATE.flows", _}
    end

    test "a collector-claimed stream keeps its shape", %{clock: clock, watched: watched} do
      bmp = config("ARANCINI_CAUSAL", owner: "bmp-collector", max_bytes: 12 * @gib)
      conn = start_nats(%{"ARANCINI_CAUSAL" => entry(bmp, @gib)})

      set_clock(clock, 10 * @grace)
      StreamOwnership.reconcile(tracker(clock), request(conn), watched)

      assert_shape(conn, "ARANCINI_CAUSAL", 12 * @gib, "bmp-collector")
      refute_received {:js, "$JS.API.STREAM.UPDATE.ARANCINI_CAUSAL", _}
    end

    test "the pre-update re-read skips a claim that appeared after the decision",
         %{clock: clock, watched: watched} do
      conn = start_nats(%{"flows" => entry(config("flows", max_bytes: 10 * @gib), 9 * @gib)})
      request = request(conn)
      set_clock(clock, 0)
      tracker = StreamOwnership.reconcile(tracker(clock), request, watched)

      # The grace period has passed; flow-collector claims the stream between
      # EventWriter's decision (the first INFO of the tick) and its update.
      claim = %{"serviceradar.owner" => "flow-collector"}

      FakeNats.on_info(conn, "flows", fn
        3, entry -> put_in(entry, ["config", "metadata"], claim)
        _count, entry -> entry
      end)

      set_clock(clock, @grace)

      log =
        capture_log(fn ->
          StreamOwnership.reconcile(tracker, request, watched)
        end)

      assert log =~ "claimed it first"
      assert_shape(conn, "flows", 10 * @gib, "flow-collector")
      refute_received {:js, "$JS.API.STREAM.UPDATE.flows", _}
    end

    test "a stream reclaimed for event-writer is reconciled at the next tick, without grace",
         %{clock: clock, watched: watched} do
      bmp = config("ARANCINI_CAUSAL", owner: "bmp-collector", max_bytes: 12 * @gib)
      conn = start_nats(%{"ARANCINI_CAUSAL" => entry(bmp, @gib)})
      request = request(conn)
      set_clock(clock, 0)
      tracker = StreamOwnership.reconcile(tracker(clock), request, watched)
      assert_shape(conn, "ARANCINI_CAUSAL", 12 * @gib, "bmp-collector")

      # The operator runs the runbook reclaim; no time passes.
      %{"config" => claimed} = FakeNats.stream(conn, "ARANCINI_CAUSAL")
      claimed = put_in(claimed, ["metadata", "serviceradar.owner"], "event-writer")
      FakeNats.put_stream(conn, "ARANCINI_CAUSAL", entry(claimed, @gib))

      StreamOwnership.reconcile(tracker, request, watched)
      assert_shape(conn, "ARANCINI_CAUSAL", @gib, "event-writer")
    end

    test "a tick only reads and updates streams", %{clock: clock, watched: watched} do
      streams = %{
        "events" => entry(config("events"), 0),
        "flows" => entry(config("flows", owner: "event-writer", max_bytes: 3 * @gib), 0),
        "ARANCINI_CAUSAL" => entry(config("ARANCINI_CAUSAL", owner: "bmp-collector"), 0)
      }

      conn = start_nats(streams)
      set_clock(clock, 0)
      tracker = StreamOwnership.reconcile(tracker(clock), request(conn), watched)
      set_clock(clock, @grace)
      StreamOwnership.reconcile(tracker, request(conn), watched)

      topics = drain_topics()
      assert topics != []
      assert Enum.reject(topics, &stream_api_topic?/1) == []

      assert_shape(conn, "flows", @gib, "event-writer")
      assert_shape(conn, "events", 2 * @gib, "event-writer")
    end
  end

  describe "consumer setup" do
    test "an absent stream is created at the fallback size with the event-writer claim" do
      conn = start_nats(%{})
      arancini = Enum.find(streams(), &(&1.name == "ARANCINI_CAUSAL"))

      assert {:ok, %{stream: "ARANCINI_CAUSAL"}} =
               Producer.setup_consumer(conn, config_for([arancini]), arancini)

      assert_received {:js, "$JS.API.STREAM.CREATE.ARANCINI_CAUSAL", body}
      created = Jason.decode!(body)

      assert created["max_bytes"] == @gib
      assert created["num_replicas"] == 1
      assert created["discard"] == "old"
      assert created["metadata"] == %{"serviceradar.owner" => "event-writer"}
    end

    test "a legacy stream only gets its subjects merged when consumers set up" do
      legacy = config("events", max_bytes: 10 * @gib, subjects: ["events.>"])
      conn = start_nats(%{"events" => entry(legacy, 9 * @gib)})
      logs = Enum.find(streams(), &(&1.name == "LOGS"))

      assert {:ok, %{stream: "events"}} = Producer.setup_consumer(conn, config_for([logs]), logs)

      assert_received {:js, "$JS.API.STREAM.UPDATE.events", _body}
      %{"config" => after_setup, "bytes" => bytes} = FakeNats.stream(conn, "events")

      assert after_setup["subjects"] == ["events.>", "logs.>"]
      assert after_setup["max_bytes"] == 10 * @gib
      assert after_setup["num_replicas"] == 1
      refute Map.has_key?(after_setup, "metadata")
      assert bytes == 9 * @gib
    end
  end

  describe "producer ownership timer" do
    test "a tick claims after the grace period and never touches a consumer", %{clock: clock} do
      streams = streams()
      conn = start_nats(%{"flows" => entry(config("flows", max_bytes: 10 * @gib), 9 * @gib)})
      config = %{config_for(streams) | ownership_reconcile_interval_ms: 20}
      consumer = %{stream: "flows", durable: "d", sid: 41, pull_subject: "_INBOX.pull.test"}
      context = %{consumers: [consumer], pull_subjects: MapSet.new(["_INBOX.pull.test"])}

      state = %Producer{
        config: config,
        conn: conn,
        connected: true,
        consumer_context: context,
        ownership: tracker(clock),
        owned_streams: StreamOwnership.watched_streams(streams)
      }

      set_clock(clock, 0)
      assert {:noreply, [], state} = Producer.handle_info(:ownership_reconcile, state)
      assert_receive :ownership_reconcile, 1_000
      assert_shape(conn, "flows", 10 * @gib, nil)

      set_clock(clock, @grace)

      {{:noreply, [], state}, _log} =
        with_log(fn -> Producer.handle_info(:ownership_reconcile, state) end)

      assert_receive :ownership_reconcile, 1_000
      assert_shape(conn, "flows", @gib, "event-writer")

      assert state.consumer_context == context
      assert state.connected
      refute_received {:unsubscribed, _sid}
      refute_received {:subscribed, _sid, _topic}
      refute Enum.any?(drain_topics(), &String.contains?(&1, ".CONSUMER."))
    end
  end

  # --- helpers ---------------------------------------------------------------

  defp streams do
    Config.apply_jetstream_sizes(
      Config.default_streams() ++ Config.default_flow_streams(),
      Config.default_jetstream_sizes()
    )
  end

  defp watched_streams, do: StreamOwnership.watched_streams(streams())

  defp watched_subjects(name), do: watched_streams() |> Map.fetch!(name) |> Map.fetch!(:subjects)

  defp config_for(streams) do
    %Config{consumer_name: "serviceradar-event-writer", streams: streams}
  end

  defp tracker(clock) do
    StreamOwnership.new(grace_period_ms: @grace, clock: fn -> :atomics.get(clock, 1) end)
  end

  defp set_clock(clock, ms), do: :atomics.put(clock, 1, ms)

  defp start_nats(streams), do: start_supervised!({FakeNats, {self(), streams}})

  defp request(conn), do: fn topic, body -> Util.request(conn, topic, body) end

  defp entry(config, bytes), do: %{"config" => config, "bytes" => bytes}

  # A stream as STREAM.INFO reports it: every subject EventWriter consumes on it,
  # and `serviceradar.owner` only when `owner:` is given (a legacy stream has no
  # metadata at all).
  defp config(name, opts \\ []) do
    subjects = Keyword.get_lazy(opts, :subjects, fn -> watched_subjects(name) end)

    base = %{
      "name" => name,
      "subjects" => subjects,
      "retention" => "limits",
      "storage" => "file",
      "discard" => "old",
      "num_replicas" => Keyword.get(opts, :replicas, 1),
      "max_bytes" => Keyword.get(opts, :max_bytes, 2 * @gib),
      "max_age" => 3_600_000_000_000
    }

    case Keyword.fetch(opts, :owner) do
      {:ok, owner} -> Map.put(base, "metadata", %{"serviceradar.owner" => owner})
      :error -> base
    end
  end

  defp assert_shape(conn, name, max_bytes, owner) do
    %{"config" => config} = FakeNats.stream(conn, name)
    assert config["max_bytes"] == max_bytes, "#{name} max_bytes"
    assert get_in(config, ["metadata", "serviceradar.owner"]) == owner, "#{name} owner"
  end

  defp stream_api_topic?(topic) do
    String.starts_with?(topic, ["$JS.API.STREAM.INFO.", "$JS.API.STREAM.UPDATE."])
  end

  defp drain_topics(acc \\ []) do
    receive do
      {:js, topic, _body} -> drain_topics([topic | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
