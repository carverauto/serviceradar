defmodule ServiceRadar.EventWriter.FlowStartupWarningsNatsTest do
  @moduledoc """
  Core startup of the EventWriter consumer reconciler against a real,
  disposable JetStream broker, configured from the release runtime config.

  After the flows stream cutover, raw flow subjects live on the dedicated
  `flows` stream and `flow.attributed.>` lives on `attributed_flow`. A consumer
  declared for one of those subjects on the shared `events` stream resolves to
  a different stream, and the reconciler logs a warning on every start. This
  test starts the reconciler and checks that no such warning appears, that every
  durable is set up, and that raw sFlow and NetFlow messages still reach their
  live durables on `flows`.

  The control case adds the consumers this change removed back into the same
  config and checks that the same broker produces those warnings. Without it,
  a passing first test could mean the check is unable to see them.

  Runs as its own Bazel target (`event_writer_flow_startup_warnings_nats_test`),
  which stages the hermetic nats-server binary under TEST_TMPDIR/external.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ServiceRadar.EventWriter.ConsumerReconciler
  alias ServiceRadar.EventWriter.ConsumerSetup
  alias ServiceRadar.EventWriter.Processors.Flows

  @moduletag timeout: 180_000

  @runtime_config Path.expand("../../../../serviceradar_core_elx/config/runtime.exs", __DIR__)
  @external_resource @runtime_config

  # Invented values: a valid-length cloak key and a database URL that is never
  # connected to.
  @release_env %{
    "EVENT_WRITER_ENABLED" => "true",
    "CLOAK_KEY" => Base.encode64(:binary.copy(<<7>>, 32)),
    "DATABASE_URL" => "ecto://user:pass@localhost/flow_startup_warnings_test",
    "SERVICERADAR_ASH_OBAN_SCHEDULER_ENABLED" => "false"
  }

  # The warnings the removed consumers caused, as ConsumerReconciler and
  # JetstreamConsumer print them.
  @drain_skip "EventWriter skipping best-effort drain consumer"
  @stream_mismatch "Requested stream not matched by subject; using discovered stream"

  defmodule QuietHealth do
    @moduledoc false
    # Stands in for StreamHealth, which writes health events to the database.
    def consumer_setup_failed(stream, reason, _attempt) do
      send(:flow_startup_warnings_test, {:setup_failed, stream, reason})
      :ok
    end

    def consumer_setup_recovered(_stream, _attempts), do: :ok
  end

  setup do
    Process.register(self(), :flow_startup_warnings_test)
    {:ok, _} = Application.ensure_all_started(:gnat)

    previous_health = Application.fetch_env(:serviceradar_core, :event_writer_stream_health)
    previous_writer = Application.fetch_env(:serviceradar_core, ServiceRadar.EventWriter)
    previous_env = Map.new(@release_env, fn {key, _} -> {key, System.get_env(key)} end)

    on_exit(fn ->
      restore_app_env(:event_writer_stream_health, previous_health)
      restore_app_env(ServiceRadar.EventWriter, previous_writer)

      Enum.each(previous_env, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end)

    Application.put_env(:serviceradar_core, :event_writer_stream_health, QuietHealth)
    Enum.each(@release_env, fn {key, value} -> System.put_env(key, value) end)

    release =
      Config.Reader.read!(@runtime_config, env: :prod)[:serviceradar_core][
        ServiceRadar.EventWriter
      ]

    assert is_list(release), "release config must enable the EventWriter"
    Application.put_env(:serviceradar_core, ServiceRadar.EventWriter, release)

    [executable] =
      Path.wildcard(Path.join(System.fetch_env!("TEST_TMPDIR"), "external/*/nats-server"))

    %{executable: executable}
  end

  @tag :tmp_dir
  test "core start sets up every durable without a flow drain or stream-mismatch warning",
       %{executable: executable, tmp_dir: dir} do
    with_broker(executable, dir, fn port ->
      config = startup_config(port)
      admin = seed_broker(config)

      {status, log} = with_log([level: :info], fn -> start_reconciler(config) end)
      File.write!(Path.join(dir, "reconciler.log"), log)
      IO.puts("---- reconciler startup log (flow/attributed lines) ----")
      log |> flow_lines() |> Enum.each(&IO.puts/1)

      refute log =~ @drain_skip
      refute log =~ @stream_mismatch
      refute log =~ "_EVENTS_DRAIN"
      refute log =~ "ATTRIBUTED_FLOW"
      assert status.ready, inspect(status)
      assert status.failed_streams == []
      refute_received {:setup_failed, _, _}

      # Live raw-flow delivery: each raw subject lands on its durable on `flows`.
      for {name, subject} <- [
            {"SFLOW_RAW", "flows.raw.sflow"},
            {"NETFLOW_RAW", "flows.raw.netflow"}
          ] do
        stream = Enum.find(config.streams, &(&1.name == name))
        assert stream.stream_name == "flows"
        durable = ConsumerSetup.durable_name(config, stream)

        assert %{"stream" => "flows"} =
                 js(admin, subject, "synthetic-#{name}", raw: true)

        assert %{"name" => ^durable, "stream_name" => "flows", "num_pending" => 1} =
                 js(admin, "$JS.API.CONSUMER.INFO.flows.#{durable}", "")

        IO.puts("live delivery: #{subject} -> flows/#{durable} num_pending=1")
      end

      # Nothing consumes raw flows or attributed flows from `events`.
      %{"consumers" => events_consumers} = js(admin, "$JS.API.CONSUMER.LIST.events", "")

      for consumer <- events_consumers do
        filter = get_in(consumer, ["config", "filter_subject"]) || ""
        refute String.starts_with?(filter, "flows.raw."), inspect(consumer["name"])
        refute String.starts_with?(filter, "flow.attributed."), inspect(consumer["name"])
      end

      %{"consumers" => attributed} = js(admin, "$JS.API.CONSUMER.LIST.attributed_flow", "")
      assert attributed == []

      stop_reconciler()
      Gnat.stop(admin)
    end)
  end

  @tag :tmp_dir
  test "control: the removed drain and ATTRIBUTED_FLOW entries do produce the warnings",
       %{executable: executable, tmp_dir: dir} do
    with_broker(executable, dir, fn port ->
      config = startup_config(port)
      removed = removed_entries(config.streams)
      config = %{config | streams: config.streams ++ removed}
      admin = seed_broker(config)

      {_status, log} = with_log([level: :info], fn -> start_reconciler(config) end)
      File.write!(Path.join(dir, "reconciler.log"), log)
      IO.puts("---- control startup log (flow/attributed lines) ----")
      log |> flow_lines() |> Enum.each(&IO.puts/1)

      assert log =~ @drain_skip
      assert log =~ "SFLOW_RAW_EVENTS_DRAIN"
      assert log =~ "NETFLOW_RAW_EVENTS_DRAIN"
      # The formatter drops the subject metadata. Only ATTRIBUTED_FLOW can print
      # this line: the first test runs the same config without it and sees none.
      assert log =~ @stream_mismatch

      stop_reconciler()
      Gnat.stop(admin)
    end)
  end

  # The release EventWriter config as ConsumerReconciler loads it on core start,
  # pointed at the disposable broker.
  defp startup_config(port) do
    config = ConsumerReconciler.default_config()

    %{
      config
      | nats: %{
          config.nats
          | host: "127.0.0.1",
            port: port,
            tls: false,
            user: nil,
            password: nil,
            jwt: nil,
            nkey_seed: nil,
            creds_file: nil
        }
    }
  end

  # The production topology after the cutover: `attributed_flow` owns the
  # attributed route. Every other stream is created by the reconciler itself.
  defp seed_broker(config) do
    {:ok, admin, _monitor} = ConsumerSetup.open(config.nats)

    created =
      js(admin, "$JS.API.STREAM.CREATE.attributed_flow", %{
        name: "attributed_flow",
        subjects: ["flow.attributed.>"],
        retention: "limits",
        storage: "file"
      })

    refute Map.has_key?(created, "error"), inspect(created)
    admin
  end

  # The entries this change deleted, rebuilt as the base commit declared them.
  defp removed_entries(streams) do
    drains =
      for %{name: name, subject: subject} <- streams, name in ["NETFLOW_RAW", "SFLOW_RAW"] do
        %{
          name: "#{name}_EVENTS_DRAIN",
          stream_name: "events",
          subject: subject,
          processor: Flows,
          batch_size: 100,
          batch_timeout: 500,
          allow_stream_fallback: false,
          reconcile_stream_shape: false,
          ensure_stream: false,
          best_effort: true,
          durable_source_name: name,
          consumer_deliver_policy_if_absent: :new
        }
      end

    attributed = %{
      name: "ATTRIBUTED_FLOW",
      stream_name: "events",
      subject: "flow.attributed.>",
      processor: Flows,
      batch_size: 50,
      batch_timeout: 500
    }

    assert length(drains) == 2
    drains ++ [attributed]
  end

  defp start_reconciler(config) do
    start_supervised!({ConsumerReconciler, config: config, name: :flow_startup_reconciler})
    await_setup(System.monotonic_time(:millisecond) + 60_000)
  end

  # Ready, or connected with only best-effort failures left (the control case).
  defp await_setup(deadline) do
    status = ConsumerReconciler.status(:flow_startup_reconciler)

    cond do
      status.ready ->
        # Let the first pass finish logging before the capture ends.
        Process.sleep(500)
        status

      System.monotonic_time(:millisecond) > deadline ->
        status

      true ->
        Process.sleep(100)
        await_setup(deadline)
    end
  end

  defp stop_reconciler, do: stop_supervised!(ConsumerReconciler)

  defp flow_lines(log) do
    log
    |> String.split("\n")
    |> Enum.filter(
      &(&1 =~ ~r/flows\.raw\.|flow\.attributed|EVENTS_DRAIN|ATTRIBUTED_FLOW|\[warning\]|\[error\]/)
    )
  end

  defp js(conn, topic, body, opts \\ []) do
    payload = if is_binary(body), do: body, else: Jason.encode!(body)
    {:ok, %{body: reply}} = Gnat.request(conn, topic, payload, receive_timeout: 5_000)

    if Keyword.get(opts, :raw, false) or reply != "" do
      Jason.decode!(reply)
    else
      %{}
    end
  end

  defp restore_app_env(key, {:ok, value}), do: Application.put_env(:serviceradar_core, key, value)
  defp restore_app_env(key, :error), do: Application.delete_env(:serviceradar_core, key)

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
