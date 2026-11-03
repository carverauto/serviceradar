defmodule ServiceRadar.FlowAttribution.ObservationsNatsTest do
  @moduledoc """
  Publishes flow-attribution observations through the real JetStream client
  onto a disposable broker.

  The broker is the NATS server default max payload (1_048_576 bytes) and a
  stream whose max message size is that same limit. A message the publisher
  failed to chunk is refused by the broker. Message ids are read back from
  the stored NATS headers, not from the publish callback.
  """
  use ExUnit.Case, async: false

  alias Serviceradar.Agent.Netprobe.V1.ExecutableOwnership
  alias Serviceradar.Agent.Netprobe.V1.FlowAttributionEvent
  alias Serviceradar.Agent.Netprobe.V1.WorkloadIdentity
  alias ServiceRadar.FlowAttribution
  alias ServiceRadar.FlowAttribution.Observations

  @moduletag timeout: 180_000

  # NATS server default max_payload. The stream rejects anything larger.
  @nats_max_payload 1_048_576
  # Contract catalog write_bytes_per_row: max payload, minus the 64 KiB header
  # margin, minus the 11-byte {"rows":[]} envelope.
  @max_row_bytes 1_048_576 - 65_536 - 11
  @stream "flows"
  @subject "flows.attribution.observations"

  setup_all do
    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, _} = Application.ensure_all_started(:telemetry)
    {:ok, _} = Application.ensure_all_started(:ssl)
    {:ok, _} = Application.ensure_all_started(:jason)
    {:ok, _} = Application.ensure_all_started(:gnat)
    Application.put_env(:opentelemetry, :traces_exporter, :none)
    {:ok, _} = Application.ensure_all_started(:opentelemetry)

    [executable] =
      Path.wildcard(Path.join(System.fetch_env!("TEST_TMPDIR"), "external/*/nats-server"))

    dir = Path.join(System.fetch_env!("TEST_TMPDIR"), "observations-nats")
    File.mkdir_p!(dir)
    {_port_ref, os_pid, port} = start_broker(executable, dir)

    {:ok, conn} =
      Gnat.start_link(%{host: "127.0.0.1", port: port}, name: :serviceradar_nats)

    ensure_stream(conn)

    on_exit(fn ->
      Gnat.stop(conn)
      System.cmd(executable, ["--signal", "quit=#{os_pid}"], stderr_to_stdout: true)
    end)

    %{conn: conn}
  end

  setup %{conn: conn} do
    js!(conn, "$JS.API.STREAM.PURGE.#{@stream}", "{}")
    :ok
  end

  test "a worst-case observation is stored once and stays within the NATS payload", %{conn: conn} do
    quotes = String.duplicate("\"", 1_200_000)

    assert :ok =
             FlowAttribution.publish_observations(
               [
                 event(
                   local_ip: String.duplicate("a", 200),
                   remote_ip: String.duplicate("b", 200),
                   comm: String.duplicate("c", 2_000),
                   redacted_cmdline: [quotes],
                   container_id: String.duplicate("d", 2_000),
                   workload_identity: %WorkloadIdentity{labels: %{"k" => quotes}},
                   executable_ownership: %ExecutableOwnership{
                     resolution_state: :EXECUTABLE_OWNERSHIP_STATE_RESOLVED,
                     source_scope: "container",
                     executable_path: quotes,
                     package_type: "apk",
                     package_manager: "apk",
                     binary_package: "example",
                     installed_version: "1",
                     resolver: :EXECUTABLE_OWNERSHIP_RESOLVER_APK
                   }
                 )
               ],
               String.duplicate("p", 400),
               String.duplicate("g", 400),
               enabled: true
             )

    messages = stored_messages(conn)
    assert length(messages) == 1
    [message] = messages
    assert message["subject"] == @subject
    body = message_data(message)
    assert byte_size(body) <= @nats_max_payload
    assert byte_size(body) - 11 <= @max_row_bytes

    assert {:ok, [row]} = Observations.decode(body)
    assert byte_size(row["partition"]) <= 128
    assert byte_size(row["agent_id"]) <= 256
    assert byte_size(row["local_ip"]) <= 64
    assert byte_size(row["remote_ip"]) <= 64
    assert byte_size(row["comm"]) <= 256
    assert byte_size(row["cmdline"]) <= 65_533
    assert byte_size(row["container_id"]) <= 256

    IO.puts(
      "EVIDENCE worst_case_message_bytes=#{byte_size(body)} row_bytes=#{byte_size(body) - 11} nats_max=#{@nats_max_payload} row_cap=#{@max_row_bytes}"
    )
  end

  test "a retried 16-byte event id stores each split once under a header-safe id", %{conn: conn} do
    events = for port <- 1..501, do: event(local_port: port)

    event_id = <<
      0x01,
      0x92,
      0xAA,
      0xBB,
      0xCC,
      0xDD,
      0x0A,
      0x0D,
      0x80,
      0x00,
      0x80,
      0x00,
      0x11,
      0x22,
      0x33,
      0x44
    >>

    assert :ok =
             FlowAttribution.publish_observations(events, "site-a", "agent-a",
               enabled: true,
               event_id: event_id
             )

    first = stored_messages(conn)
    assert length(first) > 1
    assert Enum.all?(first, &(byte_size(message_data(&1)) <= @nats_max_payload))

    ids = Enum.map(first, &message_id!/1)
    assert ids == Enum.map(0..(length(ids) - 1), &"0192aabb-ccdd-0a0d-8000-800011223344:#{&1}")
    assert Enum.all?(ids, &(not String.contains?(&1, ["\r", "\n"])))

    assert :ok =
             FlowAttribution.publish_observations(events, "site-a", "agent-a",
               enabled: true,
               event_id: event_id
             )

    second = stored_messages(conn)
    assert length(second) == length(first)
    assert Enum.map(second, &message_id!/1) == ids

    IO.puts(
      "EVIDENCE splits=#{length(ids)} ids=#{inspect(ids)} max_message_bytes=#{Enum.max(Enum.map(first, &byte_size(message_data(&1))))}"
    )
  end

  test "a non-token event id is stored as lowercase hex", %{conn: conn} do
    assert :ok =
             FlowAttribution.publish_observations([event()], "site-a", "agent-a",
               enabled: true,
               event_id: "edge\r\n1"
             )

    [message] = stored_messages(conn)
    assert message["subject"] == @subject
    assert message_id!(message) == "656467650d0a31:0"
    IO.puts("EVIDENCE non_token_msg_id=656467650d0a31:0")
  end

  test "a nested key that cannot fit its column publishes nothing", %{conn: conn} do
    label = String.duplicate("k", 1_048_576)

    assert {:error, {:flow_attribution_publish_failed, :observation_exceeds_max_payload}} =
             FlowAttribution.publish_observations(
               [event(workload_identity: %WorkloadIdentity{labels: %{label => "x"}})],
               "site-a",
               "agent-a",
               enabled: true
             )

    assert stored_messages(conn) == []

    key = String.duplicate("k", 65_533)

    assert {:error, :observation_exceeds_max_payload} =
             Observations.publish([%{"executable_ownership" => %{key => "x"}}])

    assert stored_messages(conn) == []
    IO.puts("EVIDENCE unfit_nested_key published=0")
  end

  defp event(overrides \\ []) do
    struct!(
      %FlowAttributionEvent{
        local_ip: "192.0.2.10",
        local_port: 44_321,
        remote_ip: "198.51.100.7",
        remote_port: 443,
        transport_protocol: "tcp",
        pid: 4242,
        uid: 1000,
        comm: "curl",
        redacted_cmdline: ["curl", "https://host01.example.com"],
        container_id: "c0ffee",
        observed_at_unix_nano: 1_790_000_000_123_456_000
      },
      overrides
    )
  end

  defp start_broker(executable, dir) do
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
    {port, pid, broker_port(port, dir, pid, 300, "")}
  end

  defp broker_port(port_ref, dir, pid, attempts, output) do
    output = drain_broker(port_ref, output)

    case File.read(Path.join(dir, "nats-server_#{pid}.ports")) do
      {:ok, body} ->
        %{"nats" => [uri]} = Jason.decode!(body)
        URI.parse(uri).port

      {:error, :enoent} ->
        if attempts == 0 or String.contains?(output, "nats-server exit") do
          flunk("disposable NATS broker did not start: #{output}")
        else
          Process.sleep(100)
          broker_port(port_ref, dir, pid, attempts - 1, output)
        end
    end
  end

  defp drain_broker(port_ref, output) do
    receive do
      {^port_ref, {:data, data}} -> drain_broker(port_ref, output <> data)
      {^port_ref, {:exit_status, status}} -> output <> "\nnats-server exit #{status}"
    after
      0 -> output
    end
  end

  defp ensure_stream(conn) do
    js!(conn, "$JS.API.STREAM.CREATE.#{@stream}", %{
      name: @stream,
      subjects: ["flows.attribution.>"],
      retention: "limits",
      storage: "memory",
      discard: "old",
      max_msg_size: @nats_max_payload,
      duplicate_window: 120_000_000_000,
      allow_direct: true,
      num_replicas: 1
    })
  end

  defp js!(conn, subject, payload) when is_map(payload),
    do: js!(conn, subject, Jason.encode!(payload))

  defp js!(conn, subject, payload) when is_binary(payload) do
    {:ok, %{body: body}} = Gnat.request(conn, subject, payload, receive_timeout: 5_000)
    decoded = Jason.decode!(body)

    if is_map(decoded["error"]) do
      flunk("jetstream #{subject} failed: #{body}")
    else
      decoded
    end
  end

  defp stored_messages(conn) do
    info = js!(conn, "$JS.API.STREAM.INFO.#{@stream}", "")
    last = get_in(info, ["state", "last_seq"]) || 0
    first = get_in(info, ["state", "first_seq"]) || 0

    if last == 0 or get_in(info, ["state", "messages"]) == 0 do
      []
    else
      Enum.map(first..last, fn seq ->
        response = js!(conn, "$JS.API.STREAM.MSG.GET.#{@stream}", %{seq: seq})
        response["message"] || flunk("missing message seq #{seq}: #{inspect(response)}")
      end)
    end
  end

  defp message_data(%{"data" => data}) when is_binary(data) do
    case Base.decode64(data) do
      {:ok, raw} -> raw
      :error -> data
    end
  end

  defp message_id!(message) do
    header =
      message["hdrs"] ||
        flunk("stored message has no headers: #{inspect(Map.delete(message, "data"))}")

    {:ok, raw} = Base.decode64(header)

    raw
    |> String.split("\r\n")
    |> Enum.find_value(fn line ->
      case String.split(line, ": ", parts: 2) do
        ["Nats-Msg-Id", id] -> id
        _ -> nil
      end
    end) || flunk("Nats-Msg-Id missing from #{inspect(raw)}")
  end
end
