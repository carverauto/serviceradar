defmodule ServiceRadar.BGP.IngestorDbTest do
  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.BGP.Ingestor
  alias ServiceRadar.Repo

  @moduletag :integration

  test "upserts duplicate BGP observations into a single aggregated row" do
    observation = %{
      timestamp: ~U[2026-02-15 12:34:25Z],
      source_protocol: "netflow",
      as_path: [64_512, 64_513, 64_514],
      bgp_communities: [6_553_800, 6_553_801],
      src_ip: "192.0.2.10",
      dst_ip: "198.51.100.20",
      bytes: 1_500,
      packets: 10,
      metadata: %{"sampler_address" => "192.0.2.1"}
    }

    assert {:ok, first_id} = Ingestor.upsert_observation(observation)

    assert {:ok, second_id} =
             Ingestor.upsert_observation(%{
               observation
               | timestamp: ~U[2026-02-15 12:34:55Z],
                 bytes: 500,
                 packets: 5
             })

    assert second_id == first_id

    assert {:ok, %{rows: [[count, total_bytes, total_packets, flow_count]]}} =
             Repo.query(
               """
               SELECT COUNT(*), SUM(total_bytes), SUM(total_packets), SUM(flow_count)
               FROM platform.bgp_routing_info
               WHERE timestamp = $1
                 AND source_protocol = 'netflow'
                 AND as_path = $2
               """,
               [~U[2026-02-15 12:34:00Z], [64_512, 64_513, 64_514]]
             )

    assert count == 1
    assert total_bytes == Decimal.new(2_000)
    assert total_packets == Decimal.new(15)
    assert flow_count == 2
  end
end
