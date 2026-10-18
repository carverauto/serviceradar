defmodule ServiceRadar.Integration.NetflowIngestionIntegrationTest do
  @moduledoc """
  BGP analytics read the observations derived from flows in
  `platform.bgp_routing_info`, not a per-flow table.

  Flow persistence itself (StarRocks only) is covered at the processor boundary
  by `ServiceRadar.EventWriter.Processors.FlowsWarehouseOnlyDBTest`.
  """

  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.BGP.Stats
  alias ServiceRadar.Repo

  @moduletag :integration
  @moduletag timeout: 60_000

  setup do
    Repo.delete_all("bgp_routing_info")
    :ok
  end

  describe "BGP analytics over derived observations" do
    test "BGP stats read derived observations without a legacy per-flow table" do
      now = DateTime.utc_now()

      Repo.query!(
        """
        INSERT INTO platform.bgp_routing_info (
          id,
          timestamp,
          source_protocol,
          as_path,
          bgp_communities,
          src_ip,
          dst_ip,
          total_bytes,
          total_packets,
          flow_count,
          metadata,
          created_at
        ) VALUES (
          gen_random_uuid(),
          $1,
          'netflow',
          $2,
          $3,
          $4::inet,
          $5::inet,
          $6,
          $7,
          $8,
          $9,
          NOW()
        )
        """,
        [
          now,
          [64_512, 64_513],
          [65_538_000],
          %Postgrex.INET{address: {192, 168, 1, 100}, netmask: 32},
          %Postgrex.INET{address: {8, 8, 8, 8}, netmask: 32},
          1_500_000,
          1000,
          1,
          Jason.encode!(%{"sampler_address" => "10.1.0.1"})
        ]
      )

      assert [%{as_number: 64_512, bytes: 1_500_000}] =
               Stats.get_traffic_by_as("last_1h", "netflow", 1)

      assert [%{community: 65_538_000, bytes: 1_500_000}] =
               Stats.get_top_communities("last_1h", "netflow", 1)
    end
  end
end
