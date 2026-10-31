ExUnit.start()

defmodule ServiceRadarAgentGateway.PubackMetricsScrapeTest do
  @moduledoc """
  Drives the gateway metrics plug the release serves.

  A misrouted JetStream PubAck must show up on GET /metrics as
  serviceradar_agent_gateway_jetstream_puback_error_count. A durable ack and a
  local derivation refusal must not. The expected count is 1 because the
  publisher emits `%{count: 1}` once per settled error.
  """

  use ExUnit.Case, async: false

  alias ServiceRadar.Edge.PublisherLane
  alias ServiceRadar.Edge.PublisherPool
  alias ServiceRadarAgentGateway.JetStreamPublisher

  defmodule FakeConn do
    @moduledoc false
    def get(name) do
      send(self(), {:resolved, name})
      {:ok, self()}
    end

    def request(_conn_name, _subject, _payload, _opts) do
      Process.get(:fake_reply)
    end
  end

  setup do
    Application.ensure_all_started(:telemetry)
    Application.ensure_all_started(:bandit)
    Application.ensure_all_started(:inets)
    Application.load(:plug)
    Application.put_env(:plug, :validate_header_keys_during_test, true)

    reporter = start_supervised!(ServiceRadarAgentGateway.Telemetry)

    {:ok, server} =
      Bandit.start_link(
        plug: ServiceRadarAgentGateway.MetricsRouter,
        ip: {127, 0, 0, 1},
        port: 0,
        startup_log: false
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(server)
    on_exit(fn -> Process.exit(server, :shutdown) end)

    %{port: port, reporter: reporter}
  end

  test "a misrouted PubAck is scraped and a durable ack is not", %{port: port} do
    {pub, planned} = publication()

    with_reply({:ok, %{body: ~s({"stream":"SOME_OTHER_STREAM","seq":5})}})

    assert {:error, :misrouted} =
             JetStreamPublisher.publish_record(pub, pools: pools(), connection: FakeConn)

    body = scrape(port)

    assert_count(body, "misrouted", 1)

    with_reply({:ok, %{body: ~s({"stream":"#{planned.route.expected_stream}","seq":6})}})

    assert {:ok, %{seq: 6}} =
             JetStreamPublisher.publish_record(pub, pools: pools(), connection: FakeConn)

    assert_count(scrape(port), "misrouted", 1)

    assert {:error, {:derivation, :record_bytes}} =
             JetStreamPublisher.publish_record(Map.delete(pub, :record_bytes),
               pools: pools(),
               connection: FakeConn
             )

    later = scrape(port)
    assert_count(later, "misrouted", 1)
    refute later =~ ~s(reason="record_bytes")
  end

  defp assert_count(body, reason, count) do
    line =
      body
      |> String.split("\n")
      |> Enum.find(&(&1 =~ "serviceradar_agent_gateway_jetstream_puback_error_count" and &1 =~ ~s(reason="#{reason}")))

    assert line != nil, "missing puback counter for #{reason}:\n#{body}"

    scraped =
      line
      |> String.split(" ")
      |> List.last()
      |> String.trim()
      |> Float.parse()

    assert scraped == {count / 1, ""}, line
  end

  defp scrape(port) do
    url = ~c"http://127.0.0.1:#{port}/metrics"
    assert {:ok, {{_, 200, _}, _headers, body}} = :httpc.request(:get, {url, []}, [], [])
    to_string(body)
  end

  defp with_reply(reply), do: Process.put(:fake_reply, reply)

  defp pools do
    Map.new(PublisherLane.lanes(), fn lane ->
      {:ok, pid} =
        PublisherPool.start_link(
          class: lane,
          frame_credits: 64,
          byte_credits: 64 * 1024 * 1024,
          name: nil
        )

      transport = spawn(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> Process.exit(transport, :kill) end)
      {:ok, _generation} = PublisherPool.register_transport(pid, transport)
      {lane, pid}
    end)
  end

  defp uuidv7(seed) do
    bytes = Enum.map(0..15, &rem(seed + &1, 256))

    bytes
    |> List.replace_at(6, Bitwise.bor(Bitwise.band(Enum.at(bytes, 6), 0x0F), 0x70))
    |> List.replace_at(8, Bitwise.bor(Bitwise.band(Enum.at(bytes, 8), 0x3F), 0x80))
    |> :erlang.list_to_binary()
  end

  defp publication do
    bytes = "rec"

    pub = %{
      slot: %{
        network_scope_id: uuidv7(0x40),
        authenticated_agent_id: "agent-0",
        spool_id: uuidv7(0x01),
        sequence: 7
      },
      route_profile: :EDGE_RECORD_ROUTE_PROFILE_DURABLE_RECORDS_V1,
      traffic_class: :EDGE_RECORD_TRAFFIC_CLASS_BULK,
      partition_rule: :network_scope_v1,
      record_bytes: bytes,
      record_sha256: :crypto.hash(:sha256, bytes),
      semantic_envelope_sha256: :binary.copy(<<0xAA>>, 32)
    }

    {:ok, planned} = JetStreamPublisher.plan(pub)
    {pub, planned}
  end
end
