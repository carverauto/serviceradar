defmodule ServiceRadar.Integration.NetflowIngestionIntegrationTest do
  @moduledoc """
  Integration tests for the canonical NetFlow ingest path.

  These tests verify:
  - FlowMessage protobuf reaches `platform.ocsf_network_activity`
  - BGP-capable flows derive observations into `platform.bgp_routing_info`
  - BGP analytics query the derived store instead of legacy per-flow tables
  """

  use ExUnit.Case, async: false

  import Ecto.Query

  alias Flowpb.FlowMessage
  alias ServiceRadar.BGP.Stats
  alias ServiceRadar.Repo

  @moduletag :integration
  @moduletag timeout: 60_000

  setup do
    Repo.delete_all("bgp_routing_info")
    Repo.delete_all("ocsf_network_activity")
    :ok
  end

  describe "FlowMessage → NATS → EventWriter → PostgreSQL pipeline" do
    @tag :nats_required
    test "persists canonical flow row and derived BGP observation" do
      flow = %FlowMessage{
        type: :IPFIX,
        time_received_ns: System.system_time(:nanosecond),
        time_flow_start_ns: System.system_time(:nanosecond) - 10_000_000_000,
        time_flow_end_ns: System.system_time(:nanosecond) - 5_000_000_000,
        sampler_address: <<10, 1, 0, 1>>,
        src_addr: <<192, 168, 1, 100>>,
        dst_addr: <<8, 8, 8, 8>>,
        src_port: 49_152,
        dst_port: 443,
        proto: 6,
        bytes: 1_500_000,
        packets: 1000,
        bytes_in: 900_000,
        bytes_out: 600_000,
        packets_in: 600,
        packets_out: 400,
        in_if: 10,
        out_if: 20,
        as_path: [64_512, 64_513, 64_514],
        bgp_communities: [4_259_840_100, 4_259_840_200]
      }

      {:ok, conn} = Gnat.start_link(%{host: "localhost", port: 4222})
      on_exit(fn -> Gnat.stop(conn) end)

      :ok = Gnat.pub(conn, "flows.raw.netflow", FlowMessage.encode(flow))

      Process.sleep(1000)

      flow_row =
        Repo.one(
          from(f in "ocsf_network_activity",
            where: f.src_endpoint_ip == "192.168.1.100",
            select: %{
              src_endpoint_ip: f.src_endpoint_ip,
              dst_endpoint_ip: f.dst_endpoint_ip,
              bytes_total: f.bytes_total,
              packets_total: f.packets_total,
              bytes_in: f.bytes_in,
              bytes_out: f.bytes_out,
              packets_in: f.packets_in,
              packets_out: f.packets_out
            }
          )
        )

      assert flow_row
      assert flow_row.src_endpoint_ip == "192.168.1.100"
      assert flow_row.dst_endpoint_ip == "8.8.8.8"
      assert flow_row.bytes_total == 1_500_000
      assert flow_row.packets_total == 1000
      assert flow_row.bytes_in == 900_000
      assert flow_row.bytes_out == 600_000
      assert flow_row.packets_in == 600
      assert flow_row.packets_out == 400

      {:ok, result} =
        Repo.query(
          """
          SELECT src_ip, dst_ip, as_path, bgp_communities, total_bytes, total_packets
          FROM platform.bgp_routing_info
          WHERE src_ip = $1::inet
          ORDER BY timestamp DESC
          LIMIT 1
          """,
          ["192.168.1.100"]
        )

      assert [[src_ip, dst_ip, as_path, communities, total_bytes, total_packets]] = result.rows
      assert src_ip == %Postgrex.INET{address: {192, 168, 1, 100}, netmask: 32}
      assert dst_ip == %Postgrex.INET{address: {8, 8, 8, 8}, netmask: 32}
      assert as_path == [64_512, 64_513, 64_514]
      assert communities == [4_259_840_100, 4_259_840_200]
      assert total_bytes == 1_500_000
      assert total_packets == 1000
    end

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
          [4_259_840_100],
          "192.168.1.100",
          "8.8.8.8",
          1_500_000,
          1000,
          1,
          Jason.encode!(%{"sampler_address" => "10.1.0.1"})
        ]
      )

      assert [%{as_number: 64_512, bytes: 1_500_000}] = Stats.get_traffic_by_as("last_1h", "netflow", 1)
      assert [%{community: 4_259_840_100, bytes: 1_500_000}] = Stats.get_top_communities("last_1h", "netflow", 1)
    end
  end
end
