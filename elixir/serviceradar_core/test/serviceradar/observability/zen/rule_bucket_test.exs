defmodule ServiceRadar.Observability.Zen.RuleBucketTest do
  @moduledoc """
  The rule bucket on a real, disposable nats-server: what `ensure/0` creates is
  what a collector's key-value reader needs, and `put/2` reports what the
  bucket refuses.
  """
  use ExUnit.Case, async: false

  alias Gnat.Jetstream.API.KV
  alias ServiceRadar.Observability.Zen.RuleBucket
  alias ServiceRadar.Reload.TaskSupervisor
  alias ServiceRadar.TestSupport.ExposureBroker

  @moduletag :db_free
  @moduletag :tmp_dir
  @moduletag timeout: 120_000

  @stream "KV_serviceradar-zen-rules"
  @key "zen/rulesets/events/logs.syslog.json"

  setup do
    if is_nil(Process.whereis(TaskSupervisor)),
      do: start_supervised!({Task.Supervisor, name: TaskSupervisor})

    original = Application.get_env(:serviceradar_core, RuleBucket)

    on_exit(fn ->
      if is_nil(original),
        do: Application.delete_env(:serviceradar_core, RuleBucket),
        else: Application.put_env(:serviceradar_core, RuleBucket, original)
    end)
  end

  test "keeps only the latest bundle per key, in a file-backed bucket readers get directly",
       ctx do
    Application.put_env(:serviceradar_core, RuleBucket, max_bytes: 65_536, replicas: 1)

    ExposureBroker.with_broker(ctx.tmp_dir, fn conn, _port ->
      assert :ok = RuleBucket.ensure()

      assert :ok = RuleBucket.put(@key, ~s({"digest":"sha256:first"}))
      assert :ok = RuleBucket.put(@key, ~s({"digest":"sha256:second"}))

      assert KV.get_value(conn, RuleBucket.bucket(), @key) == ~s({"digest":"sha256:second"})
      assert RuleBucket.keys() == {:ok, [@key]}

      %{"config" => config, "state" => state} =
        ExposureBroker.request(conn, "$JS.API.STREAM.INFO.#{@stream}", %{})

      assert state["messages"] == 1
      assert config["max_bytes"] == 65_536
      assert config["max_age"] == 0
      assert config["storage"] == "file"
      assert config["allow_direct"] == true
    end)
  end

  test "a bundle the bucket's cap cannot hold is refused with the broker's error", ctx do
    Application.put_env(:serviceradar_core, RuleBucket, max_bytes: 4_096, replicas: 1)

    ExposureBroker.with_broker(ctx.tmp_dir, fn conn, _port ->
      assert :ok = RuleBucket.ensure()
      assert :ok = RuleBucket.put(@key, ~s({"digest":"sha256:small"}))

      assert {:error, {:jetstream, %{"description" => "maximum bytes exceeded"}}} =
               RuleBucket.put("zen/rulesets/events/logs.otel.json", String.duplicate("x", 8_192))

      assert KV.get_value(conn, RuleBucket.bucket(), @key) == ~s({"digest":"sha256:small"})
    end)
  end

  test "a key listing the server never answers is abandoned as an error" do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listener)
    server = spawn_link(fn -> silent_nats_server(listener) end)
    on_exit(fn -> Process.exit(server, :kill) end)

    conn = ExposureBroker.connect(port)

    try do
      started = System.monotonic_time(:millisecond)
      assert {:error, :timeout} = RuleBucket.keys()
      assert System.monotonic_time(:millisecond) - started < 15_000

      assert Task.Supervisor.children(TaskSupervisor) == []
    after
      Gnat.stop(conn)
    end
  end

  test "without a NATS connection, ensure and put report it instead of raising" do
    assert {:error, :not_connected} = RuleBucket.ensure()
    assert {:error, :not_connected} = RuleBucket.put(@key, "{}")
  end

  # Accepts one client, completes the NATS handshake and then answers only
  # PING, so every JetStream request it is sent goes unanswered.
  defp silent_nats_server(listener) do
    {:ok, socket} = :gen_tcp.accept(listener)
    :ok = :gen_tcp.send(socket, ~s(INFO {"headers":true,"max_payload":1048576}\r\n))
    answer_pings(socket)
  end

  defp answer_pings(socket) do
    case :gen_tcp.recv(socket, 0) do
      {:ok, data} ->
        if String.contains?(data, "PING\r\n"), do: :gen_tcp.send(socket, "PONG\r\n")
        answer_pings(socket)

      {:error, _closed} ->
        :ok
    end
  end
end
