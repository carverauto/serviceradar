defmodule ServiceRadar.FlowAttribution.ObservationsTest do
  # Mutates the StarRocks application env, so not async.
  use ExUnit.Case, async: false

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
