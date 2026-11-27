defmodule ServiceRadar.NetworkDiscovery.TopologyGraph.EgressStitchTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.EventWriter.Processors.HorizonTopology
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.DgraphPersist
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.EgressStitch

  @moduletag :db_free

  describe "DgraphPersist.extract_interface_prefixes/1" do
    test "normalizes bare IPs, masks CIDRs, unwraps IPv4-mapped IPv6, deduplicates, and skips non-routable" do
      payloads = [
        %{
          interface_id: "sr:gw-1/eth0",
          ip_addresses: [
            "198.51.100.10",
            "198.51.100.10/30",
            "2001:db8:1::5/64",
            "::ffff:203.0.113.7",
            "127.0.0.1",
            "::1",
            "169.254.1.2",
            "fe80::1%eth0",
            "0.0.0.0",
            "::",
            "not-an-ip",
            "10.0.0.5/24",
            "fd00::1/64"
          ],
          ip_cidrs: "198.51.100.10/30, 192.0.2.9/29"
        },
        %{
          interface_id: "sr:gw-1/eth1",
          ip_addresses: ["198.51.100.9/30"]
        }
      ]

      result = DgraphPersist.extract_interface_prefixes(payloads)

      assert result.prefixes == [
               %{cidr: "198.51.100.10/32", family: "ipv4"},
               %{cidr: "198.51.100.8/30", family: "ipv4"},
               %{cidr: "2001:db8:1::/64", family: "ipv6"},
               %{cidr: "203.0.113.7/32", family: "ipv4"},
               %{cidr: "10.0.0.0/24", family: "ipv4"},
               %{cidr: "fd00::/64", family: "ipv6"},
               %{cidr: "192.0.2.8/29", family: "ipv4"}
             ]

      assert result.attachments == [
               {"sr:gw-1/eth0", "198.51.100.10/32"},
               {"sr:gw-1/eth0", "198.51.100.8/30"},
               {"sr:gw-1/eth0", "2001:db8:1::/64"},
               {"sr:gw-1/eth0", "203.0.113.7/32"},
               {"sr:gw-1/eth0", "10.0.0.0/24"},
               {"sr:gw-1/eth0", "fd00::/64"},
               {"sr:gw-1/eth0", "192.0.2.8/29"},
               {"sr:gw-1/eth1", "198.51.100.8/30"}
             ]
    end
  end

  describe "EgressStitch.plan_egress_stitches/3" do
    test "combines Tier 1 manual overrides, Device.tags fallback, Tier 2 automagic LPM, and Vantage matching" do
      targets = %{
        "prefixes" => [
          %{"id" => "198.51.100.0/24", "asn" => 64_500},
          %{"id" => "198.51.100.0/25", "asn" => 64_512},
          %{"id" => "2001:db8:2::/48", "asn" => 64_514}
        ],
        "asns" => [
          %{"id" => "asn:64512", "asn" => 64_512},
          %{"id" => "asn:64514", "asn" => 64_514}
        ],
        "vantages" => [
          %{"id" => "vantage:van-1", "ip" => "203.0.113.10", "asn" => 64_513}
        ]
      }

      candidates = %{
        devices: [
          %{uid: "sr:gw-manual", ip: "192.168.1.1", type: "router", type_id: 12, tags: %{}},
          %{uid: "sr:gw-auto", ip: "198.51.100.25", type: "router", type_id: 12, tags: %{}},
          %{
            uid: "sr:fw-tags",
            ip: "10.0.0.1",
            type: "firewall",
            type_id: 9,
            tags: %{
              "internet_egress" => "true",
              "egress_upstream_asn" => "64599",
              "egress_vantage_id" => "van-1",
              "egress_port_speed_mbps" => "2500"
            }
          },
          %{uid: "sr:internal-switch", ip: "10.0.0.2", type: "switch", type_id: 10, tags: %{}}
        ],
        interfaces: [
          %{
            device_id: "sr:gw-manual",
            interface_uid: "if-wan0",
            if_name: "xe-0/0/0",
            if_index: 10,
            ip_addresses: ["198.51.100.5", "203.0.113.10"],
            classifications: ["wan"],
            speed_bps: 1_000_000_000,
            if_speed: nil,
            metadata: %{}
          },
          %{
            device_id: "sr:gw-auto",
            interface_uid: "if-v6",
            if_name: "eth1",
            if_index: 2,
            ip_addresses: ["2001:db8:2::99", "127.0.0.1"],
            classifications: ["wan"],
            speed_bps: 10_000_000_000,
            if_speed: nil,
            metadata: %{}
          },
          %{
            device_id: "sr:internal-switch",
            interface_uid: "if-lan",
            if_name: "gi0/1",
            if_index: 1,
            ip_addresses: ["10.0.0.2"],
            classifications: ["lan"],
            speed_bps: 1_000_000_000,
            if_speed: nil,
            metadata: %{}
          }
        ],
        interface_settings: [
          %{
            device_id: "sr:gw-manual",
            interface_uid: "if-wan0",
            internet_egress: true,
            egress_upstream_asn: 64_512,
            egress_vantage_id: "vantage:van-missing",
            egress_port_speed_mbps: 10_000
          }
        ],
        agents: [
          %{device_uid: "sr:gw-auto", ip: "198.51.100.77"}
        ]
      }

      plan =
        EgressStitch.plan_egress_stitches(candidates, targets, now_iso: "2026-11-27T12:00:00Z")

      # Only missing manual anchors are created; existing asn:64512 / vantage:van-1 are reused.
      assert Enum.map(plan.nodes, & &1.id) == ["asn:64599", "vantage:van-missing"]
      assert Enum.all?(plan.nodes, &(&1.ingestor == "egress_stitch_v1"))

      # LPM chose 198.51.100.0/25 over 198.51.100.0/24 and 2001:db8:2::/48 for IPv6.
      assert {"sr:gw-manual/xe-0/0/0", "198.51.100.0/25"} in plan.prefix_attachments
      assert {"sr:gw-auto/eth1", "2001:db8:2::/48"} in plan.prefix_attachments

      manual_asn =
        Enum.find(plan.edges, &(&1.src_id == "sr:gw-manual" and &1.dst_id == "asn:64512"))

      assert manual_asn.egress_source == "manual"
      assert manual_asn.port_speed_mbps == 10_000
      assert manual_asn.if_name == "xe-0/0/0"
      assert manual_asn.if_index == 10
      assert manual_asn.ingestor == "egress_stitch_v1"

      # Vantage matched both manually and by IP
      assert Enum.any?(
               plan.edges,
               &(&1.src_id == "sr:gw-manual" and &1.dst_id == "vantage:van-1")
             )

      assert Enum.any?(
               plan.edges,
               &(&1.src_id == "sr:gw-manual" and &1.dst_id == "vantage:van-missing")
             )

      # Automagic router picked up both IPv6 interface -> asn:64514 (10G) and device/agent IPv4 -> asn:64512
      auto_v6 = Enum.find(plan.edges, &(&1.src_id == "sr:gw-auto" and &1.dst_id == "asn:64514"))
      assert auto_v6.egress_source == "automagic"
      assert auto_v6.port_speed_mbps == 10_000

      auto_v4 = Enum.find(plan.edges, &(&1.src_id == "sr:gw-auto" and &1.dst_id == "asn:64512"))
      assert auto_v4.egress_source == "automagic"

      # Firewall tags fallback resolved asn:64599 and normalized van-1 -> vantage:van-1
      fw_asn = Enum.find(plan.edges, &(&1.src_id == "sr:fw-tags" and &1.dst_id == "asn:64599"))
      assert fw_asn.egress_source == "manual"
      assert fw_asn.port_speed_mbps == 2500

      assert Enum.any?(plan.edges, &(&1.src_id == "sr:fw-tags" and &1.dst_id == "vantage:van-1"))

      # Internal RFC1918 switch must not produce any egress edges
      refute Enum.any?(plan.edges, &(&1.src_id == "sr:internal-switch"))
    end
  end

  describe "HorizonTopology egress stitch trigger" do
    test "triggers egress stitch callback when snapshot upserts nodes" do
      parent = self()

      snapshot_json =
        Jason.encode!(%{
          "schema_version" => 1,
          "generated_at" => "2026-11-27T12:00:00Z",
          "ttl_secs" => 900,
          "nodes" => [%{"id" => "asn:64512", "kind" => "ASN", "asn" => 64_512}],
          "edges" => []
        })

      assert :ok =
               HorizonTopology.process_message(
                 "serviceradar.horizon.topology.snapshot",
                 snapshot_json,
                 upsert_external_topology: fn _snap, _opts ->
                   {:ok, %{nodes_upserted: 1, edges_upserted: 0, edges_skipped: 0}}
                 end,
                 reconcile_egress_fun: fn -> send(parent, :egress_reconciled) end
               )

      assert_receive :egress_reconciled
    end
  end
end
