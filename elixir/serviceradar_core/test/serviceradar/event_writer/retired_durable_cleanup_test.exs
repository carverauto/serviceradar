defmodule ServiceRadar.EventWriter.RetiredDurableCleanupTest do
  @moduledoc """
  Disposable JetStream broker. EventWriter's producer is the thing under test:
  it deletes retired durables only after its own consumer is up.

  The names below are the upgrade contract, not a copy of the retirement list.
  `log-promotion` is the durable this pipeline already cleaned up. The other
  three are durables left by the retired Go db-event-writer, the retired zen
  rules engine, and EventWriter's former FLOW_ATTRIBUTION consumer. The live
  durable name is the default consumer base plus the EVENTS stream key. A
  custom base such as `acme-event-writer-flow-attribution` is intentionally
  left in place.
  """
  use ExUnit.Case, async: false

  alias ServiceRadar.EventWriter.Config
  alias ServiceRadar.EventWriter.Producer
  alias ServiceRadar.NATS.JetstreamConsumer

  # StreamHealth writes a database health event. This driver has no Repo, and
  # that write is not the retirement behavior. The producer still calls whatever
  # module is configured, so the callback shape stays the one it uses in prod.
  defmodule QuietHealth do
    def consumer_setup_failed(_stream, _reason, _attempt), do: :ok
    def consumer_setup_recovered(_stream, _attempts), do: :ok
  end

  @stream "events"
  @live "serviceradar-event-writer-events"
  @decoy "acme-event-writer-flow-attribution"
  @retired [
    "log-promotion",
    "db-event-writer",
    "zen-consumer",
    "serviceradar-event-writer-flow-attribution"
  ]
  @producers [:retired_probe_broken, :retired_probe_good, :retired_probe_again]

  @tag :tmp_dir
  test "startup deletes only the retired events durables", %{tmp_dir: dir} do
    {:ok, _} = Application.ensure_all_started(:gnat)

    Application.put_env(
      :serviceradar_core,
      :event_writer_stream_health,
      __MODULE__.QuietHealth
    )

    System.delete_env("EVENT_WRITER_CONSUMER_NAME")
    System.delete_env("EVENT_WRITER_NATS_URL")

    [executable] =
      Path.wildcard(Path.join(System.fetch_env!("TEST_TMPDIR"), "external/*/nats-server"))

    try do
      with_broker(executable, dir, fn conn ->
        seed_backlog(conn)
        before = snapshot(conn)
        assert before.messages == 4

        for name <- @retired ++ [@live, @decoy] do
          assert before.pending[name] > 0, "#{name} started with no backlog"
        end

        # A live consumer that cannot start must leave the backlog durables alone.
        port = broker_port(dir)
        broken = start_producer!(broken_config(port), :retired_probe_broken)
        Process.sleep(1_000)
        during_failure = snapshot(conn)
        assert during_failure.consumers == before.consumers
        assert during_failure.pending == before.pending
        assert Producer.status(:retired_probe_broken).ready == false
        stop_producer(broken)

        good = start_producer!(live_config(port), :retired_probe_good)
        cleaned = await_cleanup(conn)
        assert cleaned.consumers == MapSet.new([@live, @decoy])
        assert cleaned.pending[@live] == before.pending[@live]
        assert cleaned.pending[@decoy] == before.pending[@decoy]
        assert cleaned.messages == before.messages
        assert Producer.status(:retired_probe_good).ready == true
        stop_producer(good)

        # A second boot, and a name this install never had, both stay a no-op.
        again = start_producer!(live_config(port), :retired_probe_again)
        still = await_cleanup(conn)
        assert still.consumers == cleaned.consumers
        assert Producer.status(:retired_probe_again).ready == true

        assert JetstreamConsumer.delete_durable(conn, @stream, "db-event-writer") ==
                 {:ok, :absent}

        assert JetstreamConsumer.delete_durable(conn, @stream, "not-a-real-durable") ==
                 {:ok, :absent}

        stop_producer(again)

        IO.puts(
          "retired_durable_cleanup " <>
            "failure_kept=#{inspect(Enum.sort(during_failure.consumers))} " <>
            "after=#{inspect(Enum.sort(cleaned.consumers))} " <>
            "live_pending=#{cleaned.pending[@live]} " <>
            "decoy_pending=#{cleaned.pending[@decoy]} " <>
            "stream_messages=#{cleaned.messages} " <>
            "second_boot_ready=true absent_delete=ok"
        )
      end)
    after
      Enum.each(@producers, &stop_named/1)
      File.rm_rf!(dir)
    end
  end

  defp seed_backlog(conn) do
    js!(conn, "$JS.API.STREAM.CREATE.#{@stream}", %{
      name: @stream,
      subjects: ["events.>", "logs.>"],
      storage: "file",
      retention: "limits",
      discard: "old"
    })

    for {subject, body} <- [
          {"events.ocsf", "db-event-writer backlog"},
          {"logs.syslog", "zen-consumer backlog"},
          {"events.flow.attribution", "flow-attribution backlog"},
          {"events.live", "live events backlog"}
        ] do
      published = js!(conn, subject, body)
      assert is_integer(published["seq"]), inspect(published)
    end

    for {name, filter} <- [
          {"db-event-writer", "events.>"},
          {"log-promotion", "events.>"},
          {"zen-consumer", "logs.>"},
          {"serviceradar-event-writer-flow-attribution", "events.flow.attribution"},
          {@live, "events.>"},
          {@decoy, "events.flow.attribution"}
        ] do
      js!(conn, "$JS.API.CONSUMER.DURABLE.CREATE.#{@stream}.#{name}", %{
        stream_name: @stream,
        config: %{
          durable_name: name,
          filter_subject: filter,
          ack_policy: "explicit",
          deliver_policy: "all"
        }
      })
    end
  end

  defp live_config(port) do
    Application.put_env(:serviceradar_core, ServiceRadar.EventWriter,
      streams: [
        %{
          name: "EVENTS",
          stream_name: @stream,
          subject: "events.>",
          processor: ServiceRadar.EventWriter.Processors.Events,
          batch_size: 100,
          batch_timeout: 1_000,
          ensure_stream: false,
          allow_stream_fallback: false
        }
      ]
    )

    config = Config.load()
    assert config.consumer_name == "serviceradar-event-writer"

    %{config | nats: nats(port), producer_name: :retired_probe_good}
  end

  defp broken_config(port) do
    %{
      live_config(port)
      | producer_name: :retired_probe_broken,
        streams: [
          %{
            name: "MISSING",
            stream_name: "does-not-exist",
            subject: "retire.probe.missing",
            processor: ServiceRadar.EventWriter.Processors.Events,
            ensure_stream: false,
            allow_stream_fallback: false,
            batch_size: 1,
            batch_timeout: 1_000
          }
        ]
    }
  end

  defp nats(port) do
    %{
      host: "127.0.0.1",
      port: port,
      user: nil,
      password: nil,
      tls: false,
      jwt: nil,
      nkey_seed: nil,
      creds_file: nil
    }
  end

  defp start_producer!(config, name) do
    config = %{config | producer_name: name}
    {:ok, pid} = Producer.start_link(config)
    pid
  end

  defp await_cleanup(conn) do
    Enum.reduce_while(1..50, snapshot(conn), fn _, _last ->
      shot = snapshot(conn)

      if shot.consumers == MapSet.new([@live, @decoy]) do
        {:halt, shot}
      else
        Process.sleep(100)
        {:cont, shot}
      end
    end)
    |> tap(fn shot ->
      assert shot.consumers == MapSet.new([@live, @decoy]), inspect(Enum.sort(shot.consumers))
    end)
  end

  defp snapshot(conn) do
    info = js!(conn, "$JS.API.STREAM.INFO.#{@stream}")
    listed = js!(conn, "$JS.API.CONSUMER.NAMES.#{@stream}", %{})
    names = MapSet.new(listed["consumers"] || [])

    pending =
      Map.new(names, fn name ->
        body = js!(conn, "$JS.API.CONSUMER.INFO.#{@stream}.#{name}")
        {name, body["num_pending"]}
      end)

    %{messages: info["state"]["messages"], consumers: names, pending: pending}
  end

  # Direct get publishes into the stream and returns the pub ack, so a missed
  # capture fails here instead of as a mysterious empty backlog later.
  defp js!(conn, subject, payload \\ %{}) do
    body = if is_binary(payload), do: payload, else: Jason.encode!(payload)

    {:ok, %{body: raw}} = Gnat.request(conn, subject, body, receive_timeout: 10_000)
    decoded = Jason.decode!(raw)
    refute Map.has_key?(decoded, "error"), "#{subject} #{inspect(decoded)}"
    decoded
  end

  defp broker_port(dir) do
    [path] = Path.wildcard(Path.join(dir, "nats-server_*.ports"))
    %{"nats" => [uri]} = path |> File.read!() |> Jason.decode!()
    URI.parse(uri).port
  end

  defp stop_producer(pid) when is_pid(pid) do
    if Process.alive?(pid), do: GenStage.stop(pid, :normal, 5_000)
  end

  defp stop_named(name) do
    case Process.whereis(name) do
      pid when is_pid(pid) -> stop_producer(pid)
      _ -> :ok
    end
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
      uri = await_broker_uri(dir, pid, 300)
      {:ok, conn} = Gnat.start_link(%{host: "127.0.0.1", port: URI.parse(uri).port})

      try do
        fun.(conn)
      after
        Gnat.stop(conn)
      end
    after
      {_output, 0} = System.cmd(executable, ["--signal", "quit=#{pid}"], stderr_to_stdout: true)
      assert_receive {^port, {:exit_status, status}}, 30_000
      assert status == 0
    end
  end

  defp await_broker_uri(dir, pid, attempts) do
    path = Path.join(dir, "nats-server_#{pid}.ports")

    case File.read(path) do
      {:ok, body} ->
        %{"nats" => [uri]} = Jason.decode!(body)
        uri

      {:error, :enoent} ->
        assert attempts > 0, "disposable NATS broker did not start"
        Process.sleep(100)
        await_broker_uri(dir, pid, attempts - 1)
    end
  end
end
