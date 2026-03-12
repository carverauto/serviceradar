defmodule ServiceRadar.Observability.MtrHypertableIntegrationTest do
  @moduledoc """
  Integration tests for MTR trace and hop insertion into hypertables.
  """

  use ExUnit.Case, async: false

  @moduletag :integration

  alias Ecto.Adapters.SQL
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Observability.MtrHop
  alias ServiceRadar.Observability.MtrMetricsIngestor
  alias ServiceRadar.Observability.MtrTrace
  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport

  require Ash.Query

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  test "ingest/2 inserts trace and hops into hypertables" do
    actor = SystemActor.system(:test)
    agent_id = "test-mtr-agent-#{System.unique_integer([:positive])}"

    payload = %{
      "results" => [
        %{
          "check_id" => "chk-mtr-001",
          "check_name" => "mtr-to-8.8.8.8",
          "target" => "8.8.8.8",
          "device_id" => "dev-router",
          "available" => true,
          "trace" => %{
            "target" => "8.8.8.8",
            "target_ip" => "8.8.8.8",
            "target_reached" => true,
            "total_hops" => 3,
            "protocol" => "icmp",
            "ip_version" => 4,
            "packet_size" => 64,
            "timestamp" => System.os_time(:second),
            "hops" => [
              %{
                "hop_number" => 1,
                "addr" => "10.0.0.1",
                "hostname" => "gw.local",
                "asn" => %{"asn" => 64_512, "org" => "Test-AS"},
                "sent" => 10,
                "received" => 10,
                "loss_pct" => 0.0,
                "last_us" => 500,
                "avg_us" => 480,
                "min_us" => 450,
                "max_us" => 550
              },
              %{
                "hop_number" => 2,
                "addr" => "203.0.113.1",
                "hostname" => "transit.example",
                "sent" => 10,
                "received" => 9,
                "loss_pct" => 10.0,
                "avg_us" => 12_000
              },
              %{
                "hop_number" => 3,
                "addr" => "8.8.8.8",
                "hostname" => "dns.google",
                "sent" => 10,
                "received" => 10,
                "loss_pct" => 0.0,
                "avg_us" => 15_000
              }
            ]
          }
        }
      ]
    }

    status = %{
      agent_id: agent_id,
      gateway_id: "gw-test",
      partition: "default"
    }

    assert :ok = MtrMetricsIngestor.ingest(payload, status)

    # Read back traces
    {:ok, traces} =
      MtrTrace
      |> Ash.Query.for_read(:by_agent, %{agent_id: agent_id})
      |> Ash.read(actor: actor)

    assert length(traces) == 1
    trace = hd(traces)
    assert trace.target_ip == "8.8.8.8"
    assert trace.total_hops == 3
    assert trace.protocol == "icmp"
    assert trace.ip_version == 4
    assert trace.target_reached == true
    assert trace.agent_id == agent_id
    assert trace.check_id == "chk-mtr-001"

    # Read back hops
    {:ok, hops} =
      MtrHop
      |> Ash.Query.for_read(:by_trace, %{trace_id: trace.id})
      |> Ash.read(actor: actor)

    assert length(hops) == 3

    sorted_hops = Enum.sort_by(hops, & &1.hop_number)
    hop1 = hd(sorted_hops)
    assert hop1.addr == "10.0.0.1"
    assert hop1.hostname == "gw.local"
    assert hop1.avg_us == 480
    assert hop1.loss_pct == 0.0
    assert hop1.sent == 10
    assert hop1.received == 10

    hop2 = Enum.at(sorted_hops, 1)
    assert hop2.addr == "203.0.113.1"
    assert hop2.loss_pct == 10.0
  end

  test "ingest/2 handles multiple results in one payload" do
    actor = SystemActor.system(:test)
    agent_id = "test-mtr-multi-#{System.unique_integer([:positive])}"

    payload = %{
      "results" => [
        %{
          "check_id" => "chk-a",
          "target" => "1.1.1.1",
          "available" => true,
          "trace" => %{
            "target_ip" => "1.1.1.1",
            "target_reached" => true,
            "total_hops" => 1,
            "protocol" => "icmp",
            "ip_version" => 4,
            "timestamp" => System.os_time(:second),
            "hops" => [
              %{"hop_number" => 1, "addr" => "1.1.1.1", "sent" => 5, "received" => 5}
            ]
          }
        },
        %{
          "check_id" => "chk-b",
          "target" => "9.9.9.9",
          "available" => true,
          "trace" => %{
            "target_ip" => "9.9.9.9",
            "target_reached" => true,
            "total_hops" => 2,
            "protocol" => "udp",
            "ip_version" => 4,
            "timestamp" => System.os_time(:second),
            "hops" => [
              %{"hop_number" => 1, "addr" => "10.0.0.1", "sent" => 5, "received" => 5},
              %{"hop_number" => 2, "addr" => "9.9.9.9", "sent" => 5, "received" => 5}
            ]
          }
        }
      ]
    }

    status = %{agent_id: agent_id, gateway_id: "gw-test", partition: "default"}
    assert :ok = MtrMetricsIngestor.ingest(payload, status)

    {:ok, traces} =
      MtrTrace
      |> Ash.Query.for_read(:by_agent, %{agent_id: agent_id})
      |> Ash.read(actor: actor)

    assert length(traces) == 2
    targets = Enum.map(traces, & &1.target_ip) |> Enum.sort()
    assert targets == ["1.1.1.1", "9.9.9.9"]
  end

  test "by_target_ip read action filters correctly" do
    actor = SystemActor.system(:test)
    agent_id = "test-mtr-target-#{System.unique_integer([:positive])}"

    for target <- ["192.0.2.1", "198.51.100.1"] do
      payload = %{
        "results" => [
          %{
            "check_id" => "chk-#{target}",
            "target" => target,
            "available" => true,
            "trace" => %{
              "target_ip" => target,
              "target_reached" => true,
              "total_hops" => 1,
              "protocol" => "icmp",
              "ip_version" => 4,
              "timestamp" => System.os_time(:second),
              "hops" => []
            }
          }
        ]
      }

      assert :ok = MtrMetricsIngestor.ingest(payload, %{agent_id: agent_id})
    end

    {:ok, traces} =
      MtrTrace
      |> Ash.Query.for_read(:by_target_ip, %{target_ip: "192.0.2.1"})
      |> Ash.read(actor: actor)

    assert Enum.all?(traces, &(&1.target_ip == "192.0.2.1"))
  end

  test "raw SQL confirms hypertable storage" do
    agent_id = "test-mtr-raw-#{System.unique_integer([:positive])}"

    payload = %{
      "results" => [
        %{
          "check_id" => "chk-raw",
          "target" => "10.99.99.99",
          "available" => true,
          "trace" => %{
            "target_ip" => "10.99.99.99",
            "target_reached" => false,
            "total_hops" => 2,
            "protocol" => "icmp",
            "ip_version" => 4,
            "timestamp" => System.os_time(:second),
            "hops" => [
              %{"hop_number" => 1, "addr" => "10.0.0.1", "sent" => 3, "received" => 3},
              %{"hop_number" => 2, "addr" => nil, "sent" => 3, "received" => 0}
            ]
          }
        }
      ]
    }

    assert :ok = MtrMetricsIngestor.ingest(payload, %{agent_id: agent_id})

    {:ok, %{rows: rows}} =
      SQL.query(
        Repo,
        "SELECT target_ip, total_hops, target_reached FROM mtr_traces WHERE agent_id = $1",
        [agent_id]
      )

    assert length(rows) == 1
    [[target_ip, total_hops, target_reached]] = rows
    assert target_ip == "10.99.99.99"
    assert total_hops == 2
    assert target_reached == true
  end
end
