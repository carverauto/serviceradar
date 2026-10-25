defmodule ServiceRadar.EventWriter.SharedDurableNatsTest do
  @moduledoc """
  Two EventWriter producers, as on two core replicas, bound to one durable on a
  real, disposable JetStream broker.

  The durable is created by the coordinator's reconciler path; the producers
  only bind it. The broker hands each message to exactly one producer, both
  producers take part, and a producer that dies holding unacknowledged messages
  loses none of them: the broker redelivers them to the survivor after ack_wait.

  Runs as its own Bazel target (`event_writer_shared_durable_nats_test`), which
  stages the hermetic nats-server binary under TEST_TMPDIR/external.
  """
  use ExUnit.Case, async: false

  alias ServiceRadar.EventWriter.Config
  alias ServiceRadar.EventWriter.ConsumerReconciler
  alias ServiceRadar.EventWriter.Producer

  @moduletag timeout: 120_000

  @subject "synthetic.events.load"
  @ack_wait_ns 2_000_000_000

  defmodule Sink do
    @moduledoc false
    # Stands in for a Broadway pipeline: reports every event and ACKs it,
    # unless told to hold its events unacknowledged.
    use GenStage

    def start_link({producer, owner, label, mode}),
      do: GenStage.start_link(__MODULE__, {producer, owner, label, mode})

    @impl true
    def init({producer, owner, label, mode}) do
      {:consumer, %{owner: owner, label: label, mode: mode},
       subscribe_to: [{producer, max_demand: 8, min_demand: 1}]}
    end

    @impl true
    def handle_events(events, _from, state) do
      Enum.each(events, fn event ->
        delivery = event.metadata.jetstream_ack.delivery_count
        send(state.owner, {:received, state.label, event.data, delivery})
        if state.mode == :ack, do: event.ack_data.ack_fun.(:ack)
      end)

      {:noreply, [], state}
    end
  end

  @tag :tmp_dir
  test "two producers on one durable each process a message once, and a dead one's redeliver",
       %{tmp_dir: dir} do
    {:ok, _} = Application.ensure_all_started(:gnat)

    [executable] =
      Path.wildcard(Path.join(System.fetch_env!("TEST_TMPDIR"), "external/*/nats-server"))

    with_broker(executable, dir, fn port ->
      config = config(port)
      [stream] = config.streams
      {:ok, admin, _monitor} = ServiceRadar.EventWriter.ConsumerSetup.open(config.nats)
      assert :ok = ConsumerReconciler.ensure_stream(admin, config, stream)

      # Phase 1: both producers ACK. Every message is processed exactly once,
      # and the work is shared.
      alpha = start_producer(config, :synthetic_alpha, :alpha, :ack)
      _bravo = start_producer(config, :synthetic_bravo, :bravo, :ack)
      await_producers([:synthetic_alpha, :synthetic_bravo])
      published = publish(admin, "first", 200)

      received = collect(200, 20_000)
      assert Enum.sort(Enum.map(received, &elem(&1, 1))) == Enum.sort(published)
      by_label = Enum.frequencies_by(received, &elem(&1, 0))
      assert by_label[:alpha] > 0 and by_label[:bravo] > 0, inspect(by_label)
      refute_receive {:received, _, _, _}, 1_000

      # Phase 2: a third producer holds what it pulls and dies before ACKing,
      # as a replica that crashes mid-batch. Every message still reaches a
      # surviving producer, and only once.
      charlie = start_doomed_producer(config, :synthetic_charlie, :charlie)
      await_producers([:synthetic_alpha, :synthetic_bravo, :synthetic_charlie])
      second = publish(admin, "second", 200)
      assert_receive {:received, :charlie, first_held, 1}, 20_000
      stop_producer(charlie)

      {held, processed} = collect_until_processed(MapSet.new(second), [first_held], [], 30_000)

      processed_data = Enum.map(processed, &elem(&1, 0))
      assert Enum.sort(processed_data) == Enum.sort(second)

      redelivered = for {data, delivery} <- processed, data in held, do: delivery
      assert length(redelivered) == length(held)
      assert Enum.all?(redelivered, &(&1 > 1))
      refute_receive {:received, _, _, _}, 3_000

      assert %{"num_pending" => 0, "num_ack_pending" => 0} = consumer_info(admin, config)
      assert Process.alive?(alpha)
      Gnat.stop(admin)
    end)
  end

  defp config(port) do
    %Config{
      enabled: true,
      nats: %{
        host: "127.0.0.1",
        port: port,
        tls: false,
        user: nil,
        password: nil,
        jwt: nil,
        nkey_seed: nil,
        creds_file: nil
      },
      consumer_name: "synthetic-writer",
      max_ack_pending: 64,
      consumer_pull_batch_size: 4,
      ack_wait_ns: @ack_wait_ns,
      workers: 3,
      retired_consumers: [],
      streams: [
        %{
          name: "SYNTHETIC_EVENTS",
          stream_name: "synthetic_events",
          subject: "synthetic.events.>",
          stream_max_bytes: 16_777_216
        }
      ]
    }
  end

  defp start_producer(config, name, label, mode) do
    producer = start_supervised!({Producer, %{config | producer_name: name}}, id: name)
    start_supervised!({Sink, {producer, self(), label, mode}}, id: {:sink, name})
    producer
  end

  # Unlinked and unsupervised, so killing it neither reaches the test process
  # nor restarts it.
  defp start_doomed_producer(config, name, label) do
    {:ok, producer} = GenStage.start(Producer, %{config | producer_name: name}, name: name)
    {:ok, _sink} = GenStage.start(Sink, {producer, self(), label, :hold})
    producer
  end

  # A replica dying: its producer and NATS connection go away without ACKing.
  defp stop_producer(producer) do
    conn = :sys.get_state(producer).state.conn
    ref = Process.monitor(conn)
    Process.exit(producer, :kill)
    Process.exit(conn, :kill)
    assert_receive {:DOWN, ^ref, :process, ^conn, _}, 5_000
  end

  defp publish(conn, batch, count) do
    for n <- 1..count do
      payload = "#{batch}-#{n}"

      {:ok, %{body: body}} =
        Gnat.request(conn, @subject, payload, receive_timeout: 5_000)

      assert %{"seq" => seq} = Jason.decode!(body)
      assert is_integer(seq) and seq > 0
      payload
    end
  end

  defp await_producers(names) do
    await_producers(names, System.monotonic_time(:millisecond) + 20_000)
  end

  defp await_producers(names, deadline) do
    pending = Enum.reject(names, &Producer.status(&1).ready)

    if pending == [] do
      :ok
    else
      remaining = deadline - System.monotonic_time(:millisecond)

      if remaining <= 0 do
        statuses = Map.new(pending, &{&1, Producer.status(&1)})
        flunk("producers not ready before publish: #{inspect(statuses)}")
      else
        Process.sleep(min(50, remaining))
        await_producers(names, deadline)
      end
    end
  end

  defp collect(count, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    collect(count, deadline, [])
  end

  defp collect(0, _deadline, acc), do: Enum.reverse(acc)

  defp collect(count, deadline, acc) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:received, label, data, delivery} ->
        collect(count - 1, deadline, [{label, data, delivery} | acc])
    after
      remaining -> flunk("received #{length(acc)} messages, #{count} still missing")
    end
  end

  # Collects until every message in `expected` was processed by a producer that
  # ACKs, returning what the dead producer held and {data, delivery} per ACKed
  # message.
  defp collect_until_processed(expected, held, processed, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    await_processed(expected, held, processed, deadline)
  end

  defp await_processed(expected, held, processed, deadline) do
    done = MapSet.new(processed, &elem(&1, 0))

    if MapSet.subset?(expected, done) do
      {held, Enum.reverse(processed)}
    else
      remaining = max(deadline - System.monotonic_time(:millisecond), 0)

      receive do
        {:received, :charlie, data, _delivery} ->
          await_processed(expected, [data | held], processed, deadline)

        {:received, _label, data, delivery} ->
          await_processed(expected, held, [{data, delivery} | processed], deadline)
      after
        remaining ->
          flunk("#{MapSet.size(MapSet.difference(expected, done))} messages never processed")
      end
    end
  end

  defp consumer_info(conn, config) do
    durable = Config.durable_name(config.consumer_name, "SYNTHETIC_EVENTS")

    {:ok, %{body: body}} =
      Gnat.request(conn, "$JS.API.CONSUMER.INFO.synthetic_events.#{durable}", "",
        receive_timeout: 5_000
      )

    Jason.decode!(body)
  end

  defp with_broker(executable, dir, fun) do
    File.mkdir_p!(dir)

    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: [
          "-js",
          "-a",
          "127.0.0.1",
          "-p",
          "-1",
          "-sd",
          Path.join(dir, "store"),
          "--ports_file_dir",
          dir,
          "-l",
          Path.join(dir, "broker.log")
        ]
      ])

    {:os_pid, pid} = Port.info(port, :os_pid)

    try do
      fun.(broker_port(dir, pid, 300))
    after
      {_output, 0} = System.cmd(executable, ["--signal", "quit=#{pid}"], stderr_to_stdout: true)
      assert_receive {^port, {:exit_status, _status}}, 30_000
    end
  end

  defp broker_port(dir, pid, attempts) do
    case File.read(Path.join(dir, "nats-server_#{pid}.ports")) do
      {:ok, body} ->
        %{"nats" => [uri]} = Jason.decode!(body)
        URI.parse(uri).port

      {:error, :enoent} ->
        assert attempts > 0, "disposable NATS broker did not start"
        Process.sleep(100)
        broker_port(dir, pid, attempts - 1)
    end
  end
end
