defmodule ServiceRadar.FlowAttribution.ObservationsTest do
  # Mutates the StarRocks application env, so not async.
  use ExUnit.Case, async: false

  alias Serviceradar.Agent.Netprobe.V1.ExecutableOwnership
  alias Serviceradar.Agent.Netprobe.V1.FlowAttributionEvent
  alias ServiceRadar.Analytics.StarRocks
  alias ServiceRadar.FlowAttribution
  alias ServiceRadar.FlowAttribution.Observations

  @moduletag :db_free

  setup do
    prev = Application.get_env(:serviceradar_core, StarRocks, [])
    on_exit(fn -> Application.put_env(:serviceradar_core, StarRocks, prev) end)
    %{prev: prev}
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

  defp capture(parent) do
    fn subject, body ->
      send(parent, {:published, subject, body})
      :ok
    end
  end

  defp collect_published(acc) do
    receive do
      {:published, _subject, body} -> collect_published([body | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp collect_ids(acc) do
    receive do
      {:published, _subject, _body, msg_id} -> collect_ids([msg_id | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "admitted events are published on the observation subject as decodable rows" do
    assert :ok =
             FlowAttribution.publish_observations([event()], "site-a", "agent-a",
               enabled: true,
               publish: capture(self())
             )

    assert_received {:published, "flows.attribution.observations", body}
    assert {:ok, [row]} = Observations.decode(body)

    assert %{
             "observed_at" => "2026-09-21T14:13:20.123456Z",
             "partition" => "site-a",
             "agent_id" => "agent-a",
             "proto" => 6,
             "local_ip" => "192.0.2.10",
             "local_port" => 44_321,
             "remote_ip" => "198.51.100.7",
             "remote_port" => 443,
             "pid" => 4242,
             "uid" => 1000,
             "comm" => "curl",
             "cmdline" => "curl https://host01.example.com",
             "container_id" => "c0ffee"
           } = row

    assert is_binary(row["attribution_key"])
  end

  # NATS refuses a payload over its max_payload; one message per edge batch
  # would fail every large batch.
  test "a large batch is split into bounded messages" do
    events = for port <- 1..501, do: event(local_port: port)

    assert :ok =
             FlowAttribution.publish_observations(events, "default", "agent-a",
               enabled: true,
               publish: capture(self())
             )

    assert_received {:published, _subject, first}
    assert_received {:published, _subject, second}
    refute_received {:published, _subject, _body}
    assert {:ok, first_rows} = Observations.decode(first)
    assert {:ok, second_rows} = Observations.decode(second)
    assert length(first_rows) + length(second_rows) == 501
  end

  test "rows with large cmdlines split into messages under the byte budget" do
    big = String.duplicate("x", 70_000)
    events = for port <- 1..20, do: event(local_port: port, redacted_cmdline: [big])

    assert :ok =
             FlowAttribution.publish_observations(events, "default", "agent-a",
               enabled: true,
               publish: capture(self())
             )

    bodies = collect_published([])
    assert length(bodies) > 1

    rows =
      Enum.flat_map(bodies, fn body ->
        # NATS server default max_payload. A larger body is a Maximum Payload Violation.
        assert byte_size(body) <= 1_048_576
        assert {:ok, decoded} = Observations.decode(body)
        decoded
      end)

    assert length(rows) == 20
    assert Enum.all?(rows, fn row -> byte_size(row["cmdline"]) <= 65_533 end)
  end

  test "rows with invalid UTF-8 bytes publish as valid UTF-8" do
    bad_comm = <<0xFF, 0xFE>>
    bad_arg = <<0xFF, 0xFE>>

    assert :ok =
             FlowAttribution.publish_observations(
               [event(comm: bad_comm, redacted_cmdline: ["curl", bad_arg])],
               "default",
               "agent-a",
               enabled: true,
               publish: capture(self())
             )

    assert_received {:published, _subject, body}
    assert {:ok, [row]} = Observations.decode(body)
    assert String.valid?(row["comm"])
    assert String.valid?(row["cmdline"])
  end

  # Column widths are the warehouse VARCHAR bounds. Filling them with quotes
  # expands under JSON encoding; the published message still has to fit in one
  # NATS payload (server default max_payload is 1_048_576 bytes).
  test "a worst-case observation row fits in one NATS message" do
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
                   workload_identity: %{labels: %{"k" => quotes}},
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
               enabled: true,
               publish: capture(self())
             )

    assert_received {:published, "flows.attribution.observations", body}
    refute_received {:published, _subject, _body}
    assert byte_size(body) <= 1_048_576
    assert {:ok, [row]} = Observations.decode(body)
    assert byte_size(row["partition"]) <= 128
    assert byte_size(row["agent_id"]) <= 256
    assert byte_size(row["local_ip"]) <= 64
    assert byte_size(row["remote_ip"]) <= 64
    assert byte_size(row["comm"]) <= 256
    assert byte_size(row["cmdline"]) <= 65_533
    assert byte_size(row["container_id"]) <= 256
    assert byte_size(row["attribution_key"]) <= 64
  end

  test "retries of one edge record reuse distinct per-split message ids" do
    events = for port <- 1..501, do: event(local_port: port)

    publish = fn subject, body, msg_id ->
      send(self(), {:published, subject, body, msg_id})
      :ok
    end

    opts = [enabled: true, event_id: "edge-record-1", publish: publish]
    assert :ok = FlowAttribution.publish_observations(events, "site-a", "agent-a", opts)
    first = collect_ids([])
    assert :ok = FlowAttribution.publish_observations(events, "site-a", "agent-a", opts)
    second = collect_ids([])

    assert length(first) > 1
    assert first == second
    assert first == Enum.map(0..(length(first) - 1), &"edge-record-1:#{&1}")
  end

  # The admission lane reports the batch as failed to the gateway, which keeps
  # it for redelivery, only if the publish failure surfaces.
  test "a refused publish fails the batch" do
    assert {:error, {:flow_attribution_publish_failed, :no_responders}} =
             FlowAttribution.publish_observations([event()], "default", "agent-a",
               enabled: true,
               publish: fn _subject, _body -> {:error, :no_responders} end
             )
  end

  test "without StarRocks nothing is published and health says why", %{prev: prev} do
    Application.put_env(
      :serviceradar_core,
      StarRocks,
      prev |> Keyword.put(:enabled, false) |> Keyword.put(:cutover_datasets, [])
    )

    assert :ok =
             FlowAttribution.publish_observations([event()], "default", "agent-a",
               publish: fn _subject, _body -> flunk("published without StarRocks") end
             )

    assert FlowAttribution.health() == %{
             enabled: false,
             attribution_disabled: :starrocks_required
           }

    Application.put_env(
      :serviceradar_core,
      StarRocks,
      prev |> Keyword.put(:enabled, true) |> Keyword.put(:cutover_datasets, [:flows])
    )

    assert FlowAttribution.health() == %{enabled: true}
  end
end
