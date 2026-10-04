defmodule ServiceRadar.EventWriter.Processors.FlowAttributionObservationsTest do
  use ExUnit.Case, async: true

  alias Serviceradar.Agent.Netprobe.V1.FlowAttributionEvent
  alias ServiceRadar.Analytics.StarRocks.Destination
  alias ServiceRadar.Analytics.StarRocks.Schema
  alias ServiceRadar.EventWriter.Processors.FlowAttributionObservations
  alias ServiceRadar.FlowAttribution

  @moduletag :db_free

  # The message core publishes for one admitted batch, built by the publisher
  # itself so the two ends of the subject cannot drift apart.
  defp published_message(events) do
    parent = self()

    :ok =
      FlowAttribution.publish_observations(events, "site-a", "agent-a",
        enabled: true,
        publish: fn _subject, body -> send(parent, {:body, body}) && :ok end
      )

    assert_received {:body, body}
    %{data: body}
  end

  defp event(overrides \\ []) do
    struct!(
      %FlowAttributionEvent{
        local_ip: "192.0.2.20",
        local_port: 8080,
        remote_ip: "0.0.0.0",
        remote_port: 0,
        transport_protocol: "tcp",
        pid: 77,
        comm: "server",
        redacted_cmdline: ["server", "--listen"],
        container_id: "abc123",
        workload_identity: %{pod_name: "web-0", pod_namespace: "shop"},
        observed_at_unix_nano: 1_790_000_000_000_000_000
      },
      overrides
    )
  end

  defp loader(parent) do
    persist = fn table, rows, _opts ->
      send(parent, {:loaded, table, rows})
      {:ok, %{loaded: length(rows)}}
    end

    &Destination.persist_warehouse(&1, &2, persist: persist)
  end

  # StarRocks JSON Stream Load ignores a key with no matching column, so a
  # renamed column would load NULL forever without an error.
  test "observations load into every column of the warehouse table" do
    message = published_message([event()])

    assert {:ok, 1} =
             FlowAttributionObservations.process_batch([message],
               starrocks_enabled: true,
               load: loader(self())
             )

    assert_received {:loaded, "flow_process_attribution_observations", [row]}

    %{statements: [_create_db, create_table]} =
      Enum.find(Schema.migrations(), &(&1.name == "flow_process_attribution_observations"))

    columns =
      ~r/^\s+`?([a-z_]+)`?\s+(?:DATETIME|VARCHAR|INT|BIGINT)/m
      |> Regex.scan(create_table, capture: :all_but_first)
      |> List.flatten()

    assert Enum.sort(Map.keys(row)) == Enum.sort(columns)

    assert %{
             "partition" => "site-a",
             "agent_id" => "agent-a",
             "proto" => 6,
             "local_ip" => "192.0.2.20",
             "local_port" => 8080,
             "remote_ip" => "0.0.0.0",
             "remote_port" => 0,
             "pid" => 77,
             "comm" => "server",
             "cmdline" => "server --listen",
             "container_id" => "abc123"
           } = row

    assert row["observed_at"] =~ ~r/^2026-09-21T14:13:20/

    assert Jason.decode!(row["workload_identity"]) == %{
             "pod_name" => "web-0",
             "pod_namespace" => "shop"
           }
  end

  test "a failed load fails the batch so JetStream redelivers it" do
    message = published_message([event()])

    assert {:error, {:warehouse_load, :flow_attribution_observations, :connect_failed}} =
             FlowAttributionObservations.process_batch([message],
               starrocks_enabled: true,
               load:
                 &Destination.persist_warehouse(&1, &2,
                   persist: fn _table, _rows, _opts -> {:error, :connect_failed} end
                 )
             )
  end

  test "an undecodable message is acknowledged without a load" do
    assert {:ok, 0} =
             FlowAttributionObservations.process_batch([%{data: "not json"}],
               starrocks_enabled: true,
               load: fn _dataset, _rows -> flunk("loaded an undecodable message") end
             )
  end
end
