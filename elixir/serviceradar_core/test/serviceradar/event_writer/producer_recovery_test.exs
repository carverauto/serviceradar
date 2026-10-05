defmodule ServiceRadar.EventWriter.ProducerRecoveryTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Cluster.CoordinatorChildren
  alias ServiceRadar.EventWriter.Config
  alias ServiceRadar.EventWriter.FlowPipeline
  alias ServiceRadar.EventWriter.FlowProducer
  alias ServiceRadar.EventWriter.Health
  alias ServiceRadar.EventWriter.Producer

  @moduletag :db_free

  # An external NATS protocol fixture, not a replacement producer. The real
  # Gnat connection, consumer setup, GenStage demand and retry timers all run.
  defmodule Broker do
    @moduledoc false
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
    def port(pid), do: GenServer.call(pid, :port)
    def allow(pid), do: GenServer.call(pid, :allow)

    @impl true
    def init(opts) do
      {:ok, listener} =
        :gen_tcp.listen(
          Keyword.get(opts, :port, 0),
          [:binary, packet: :line, active: false, reuseaddr: true, ip: {127, 0, 0, 1}]
        )

      {:ok, {_address, port}} = :inet.sockname(listener)
      mode = :atomics.new(1, [])
      :atomics.put(mode, 1, if(Keyword.get(opts, :deny, false), do: 0, else: 1))
      owner = Keyword.fetch!(opts, :owner)
      acceptor = spawn_link(fn -> accept(listener, mode, owner) end)
      {:ok, %{listener: listener, port: port, mode: mode, acceptor: acceptor}}
    end

    @impl true
    def handle_call(:port, _from, state), do: {:reply, state.port, state}

    def handle_call(:allow, _from, state) do
      :atomics.put(state.mode, 1, 1)
      {:reply, :ok, state}
    end

    @impl true
    def terminate(_reason, state) do
      :gen_tcp.close(state.listener)
      Process.exit(state.acceptor, :shutdown)
    end

    defp accept(listener, mode, owner) do
      case :gen_tcp.accept(listener) do
        {:ok, socket} ->
          worker =
            spawn_link(fn ->
              receive do
                {:socket, socket} -> serve(socket, mode, owner)
              end
            end)

          :ok = :gen_tcp.controlling_process(socket, worker)
          send(worker, {:socket, socket})
          accept(listener, mode, owner)

        {:error, :closed} ->
          :ok
      end
    end

    defp serve(socket, mode, owner) do
      :ok = :gen_tcp.send(socket, ~s(INFO {"server_id":"invented-broker","headers":false}\r\n))
      commands(socket, mode, owner, %{})
    end

    defp commands(socket, mode, owner, subscriptions) do
      case :gen_tcp.recv(socket, 0) do
        {:ok, line} ->
          case String.split(String.trim(line)) do
            ["SUB", subject, sid] ->
              commands(socket, mode, owner, Map.put(subscriptions, subject, sid))

            ["PUB", subject, reply, bytes] ->
              :ok = :inet.setopts(socket, packet: :raw)
              {:ok, payload} = :gen_tcp.recv(socket, String.to_integer(bytes) + 2)
              :ok = :inet.setopts(socket, packet: :line)
              payload = binary_part(payload, 0, String.to_integer(bytes))

              if respond(socket, subject, reply, payload, mode, owner, subscriptions) == :continue do
                commands(socket, mode, owner, subscriptions)
              end

            ["PUB", _subject, bytes] ->
              :ok = :inet.setopts(socket, packet: :raw)
              {:ok, _payload} = :gen_tcp.recv(socket, String.to_integer(bytes) + 2)
              :ok = :inet.setopts(socket, packet: :line)
              commands(socket, mode, owner, subscriptions)

            ["PING"] ->
              :ok = :gen_tcp.send(socket, "PONG\r\n")
              commands(socket, mode, owner, subscriptions)

            _ ->
              commands(socket, mode, owner, subscriptions)
          end

        {:error, :closed} ->
          :ok
      end
    end

    defp respond(socket, subject, reply, _payload, mode, owner, subscriptions) do
      cond do
        String.contains?(subject, ".CONSUMER.DURABLE.CREATE.") and :atomics.get(mode, 1) == 0 ->
          # A permissions denial followed by a broker disconnect during setup.
          # The producer must survive both and recover after access is restored.
          send(owner, {:denied, subject})
          :ok = :gen_tcp.send(socket, "-ERR 'Permissions Violation for Publish'\r\n")

          body =
            Jason.encode!(%{
              "error" => %{"code" => 403, "description" => "subject permission denied"}
            })

          sid = sid_for(subscriptions, reply)
          :ok = :gen_tcp.send(socket, "MSG #{reply} #{sid} #{byte_size(body)}\r\n#{body}\r\n")
          :gen_tcp.close(socket)
          :closed

        String.contains?(subject, ".CONSUMER.MSG.NEXT.") ->
          if String.contains?(reply, ".pull.recovery.") do
            sid = Map.fetch!(subscriptions, reply)
            body = "invented-event"

            :ok =
              :gen_tcp.send(
                socket,
                "MSG events.test.recovery #{sid} $JS.ACK.TEST_EVENTS.recovery.1.1.1.0.0 #{byte_size(body)}\r\n#{body}\r\n"
              )
          end

          :continue

        true ->
          response =
            cond do
              String.ends_with?(subject, ".STREAM.NAMES") ->
                %{"streams" => []}

              String.contains?(subject, ".STREAM.INFO.") ->
                %{"error" => %{"code" => 404, "err_code" => 10_059}}

              String.contains?(subject, ".CONSUMER.INFO.") ->
                %{"error" => %{"code" => 404}}

              true ->
                %{}
            end

          body = Jason.encode!(response)
          sid = sid_for(subscriptions, reply)
          :ok = :gen_tcp.send(socket, "MSG #{reply} #{sid} #{byte_size(body)}\r\n#{body}\r\n")
          :continue
      end
    end

    # NATS demultiplexes one connection by subscription SID: the server must
    # echo the SID of the inbox SUB the requester created. A hardcoded 0 is
    # unroutable, so the client drops the reply and every request times out.
    defp sid_for(subscriptions, reply), do: Map.get(subscriptions, reply, 0)
  end

  defmodule Sink do
    @moduledoc false
    use GenStage

    def start_link({producer, owner}), do: GenStage.start_link(__MODULE__, {producer, owner})
    @impl true
    def init({producer, owner}), do: {:consumer, owner, subscribe_to: [{producer, max_demand: 1}]}
    @impl true
    def handle_events(events, _from, owner) do
      Enum.each(events, &send(owner, {:ingested, &1.data}))
      {:noreply, [], owner}
    end
  end

  setup do
    owner = self()
    id = "producer-recovery-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      id,
      [
        [:serviceradar, :event_writer, :connection_failed],
        [:serviceradar, :event_writer, :connected]
      ],
      fn event, measurements, metadata, _ ->
        send(owner, {:connection, List.last(event), measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(id) end)
    :ok
  end

  test "denied setup subject and transport exit recover without replacing the producer" do
    broker = start_supervised!({Broker, owner: self(), deny: true})
    producer = start_supervised!({Producer, config(Broker.port(broker))})
    monitor = Process.monitor(producer)
    start_supervised!({Sink, {producer, self()}})

    assert_receive {:denied, subject}, 2_000
    assert subject =~ ".CONSUMER.DURABLE.CREATE."
    assert_receive {:connection, :connection_failed, %{retry_in_ms: delay}, _}, 3_000
    assert delay >= 5_000
    assert Producer.status().connected == false
    refute_received {:DOWN, ^monitor, :process, ^producer, _}

    :ok = Broker.allow(broker)
    assert_receive {:connection, :connected, _, _}, 10_000
    assert_receive {:ingested, "invented-event"}, 2_000
    assert %{connected: true, ready: true} = Producer.status()
    refute_received {:DOWN, ^monitor, :process, ^producer, _}
  end

  test "an unavailable broker at startup retries and begins ingestion when it appears" do
    {:ok, reservation} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}])
    {:ok, {_address, port}} = :inet.sockname(reservation)
    :ok = :gen_tcp.close(reservation)
    producer = start_supervised!({Producer, config(port)})
    monitor = Process.monitor(producer)
    start_supervised!({Sink, {producer, self()}})

    assert_receive {:connection, :connection_failed, %{attempt: 1, retry_in_ms: delay}, _}, 2_000
    assert delay >= 5_000
    assert %{connected: false, ready: false} = Producer.status()
    start_supervised!({Broker, owner: self(), port: port})

    assert_receive {:connection, :connected, _, _}, 10_000
    assert_receive {:ingested, "invented-event"}, 2_000
    refute_received {:DOWN, ^monitor, :process, ^producer, _}
  end

  test "the coordinator restarts EventWriter and health detects a stopped flow producer" do
    broker = start_supervised!({Broker, owner: self()})
    previous = Application.get_env(:serviceradar_core, ServiceRadar.EventWriter)
    previous_enabled = System.get_env("EVENT_WRITER_ENABLED")
    System.put_env("EVENT_WRITER_ENABLED", "true")

    Application.put_env(:serviceradar_core, ServiceRadar.EventWriter,
      enabled: true,
      nats: [host: "127.0.0.1", port: Broker.port(broker), tls: false],
      streams: config(Broker.port(broker)).streams,
      batch_size: 1,
      batch_timeout: 100
    )

    on_exit(fn ->
      if previous == nil,
        do: Application.delete_env(:serviceradar_core, ServiceRadar.EventWriter),
        else: Application.put_env(:serviceradar_core, ServiceRadar.EventWriter, previous)

      if previous_enabled == nil,
        do: System.delete_env("EVENT_WRITER_ENABLED"),
        else: System.put_env("EVENT_WRITER_ENABLED", previous_enabled)
    end)

    spec =
      CoordinatorChildren.children()
      |> Enum.map(&Supervisor.child_spec(&1, []))
      |> Enum.find(&(&1.id == ServiceRadar.EventWriter.Supervisor))

    # Supervisor has no child_spec/1, so start it through an explicit spec map.
    start_supervised!(%{
      id: :event_writer_coordinator_test_supervisor,
      start: {Supervisor, :start_link, [[spec], [strategy: :one_for_one]]}
    })

    assert_receive {:connection, :connected, _, %{producer: Producer}}, 3_000
    assert_receive {:connection, :connected, _, %{producer: FlowProducer}}, 3_000
    assert Health.check() == :ok

    old_conns =
      (Broadway.producer_names(ServiceRadar.EventWriter.Pipeline) ++
         Broadway.producer_names(FlowPipeline))
      |> Enum.map(&:sys.get_state(&1).conn)
      |> Enum.filter(&is_pid/1)

    assert old_conns != []

    old = Process.whereis(ServiceRadar.EventWriter.Supervisor)
    monitor = Process.monitor(old)
    :ok = Supervisor.stop(old, :shutdown)
    assert_receive {:DOWN, ^monitor, :process, ^old, :shutdown}
    Enum.each(old_conns, &refute(Process.alive?(&1)))
    assert_receive {:connection, :connected, _, %{producer: Producer}}, 3_000
    assert_receive {:connection, :connected, _, %{producer: FlowProducer}}, 3_000
    refute Process.whereis(ServiceRadar.EventWriter.Supervisor) == old
    assert Health.check() == :ok

    [flow] = Broadway.producer_names(FlowPipeline)
    :ok = :sys.suspend(flow)

    try do
      assert {:error, {:producer_not_ready, FlowPipeline}} = Health.check()
    after
      :sys.resume(flow)
    end

    assert Health.healthy?()
  end

  defp config(port) do
    %Config{
      enabled: true,
      # The full nats_config() key set: Producer.apply_auth_settings/2 reads
      # .jwt/.nkey_seed/.user/.password by key, so a partial map crashes
      # handle_info(:connect) with KeyError before any NATS traffic flows.
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
      consumer_name: "recovery",
      retired_consumers: [],
      max_ack_pending: 8,
      consumer_pull_batch_size: 1,
      streams: [
        %{
          name: "TEST_EVENTS",
          stream_name: "TEST_EVENTS",
          subject: "events.test.recovery",
          ensure_stream: false
        }
      ]
    }
  end
end
