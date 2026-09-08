defmodule ServiceRadarWebNGWeb.NetflowLive.InterfaceTrafficTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.NetflowLive.InterfaceTraffic

  @moduletag :db_free

  test "top interface queries group by concrete SNMP interface indices" do
    queries = InterfaceTraffic.top_interface_queries("in:flows time:last_1h")

    assert queries.ingress =~ "by sampler_address,input_snmp,in_if_name,in_if_speed_bps"
    assert queries.egress =~ "by sampler_address,output_snmp,out_if_name,out_if_speed_bps"
    refute queries.ingress =~ "by sampler_address sort"
    refute queries.egress =~ "by sampler_address sort"
  end

  test "projects ingress and egress rows into one physical interface" do
    ingress = [
      %{
        "payload" => %{
          "sampler_address" => "192.0.2.10",
          "input_snmp" => "12",
          "in_if_name" => "xe-0/0/0",
          "in_if_speed_bps" => "1000000000",
          "bytes_total" => 1_000
        }
      }
    ]

    egress = [
      %{
        "payload" => %{
          "sampler_address" => "192.0.2.10",
          "output_snmp" => "12",
          "out_if_name" => "xe-0/0/0",
          "out_if_speed_bps" => "1000000000",
          "bytes_total" => 2_000
        }
      },
      %{
        "payload" => %{
          "sampler_address" => "192.0.2.10",
          "output_snmp" => "13",
          "out_if_name" => "xe-0/0/1",
          "out_if_speed_bps" => "1000000000",
          "bytes_total" => 500
        }
      }
    ]

    [iface_a, iface_b] = InterfaceTraffic.project_top_interfaces(ingress, egress)

    assert iface_a.sampler == "192.0.2.10"
    assert iface_a.if_index == 12
    assert iface_a.label == "xe-0/0/0"
    assert iface_a.ingress_bytes == 1_000
    assert iface_a.egress_bytes == 2_000
    assert iface_a.bytes == 3_000
    assert iface_a.capacity_bps == 1_000_000_000

    assert iface_b.if_index == 13
    assert iface_b.bytes == 500
  end

  test "timeseries query scopes ingress and egress to the selected interface" do
    [iface] =
      InterfaceTraffic.project_top_interfaces(
        [
          %{
            "sampler_address" => "sampler \"a\"",
            "input_snmp" => "7",
            "in_if_name" => "wan0",
            "in_if_speed_bps" => "1000",
            "bytes_total" => 1
          }
        ],
        []
      )

    ingress =
      InterfaceTraffic.timeseries_query("in:flows time:last_1h", iface, :ingress, "5m", "bytes_total")

    egress =
      InterfaceTraffic.timeseries_query("in:flows time:last_1h", iface, :egress, "5m", "bytes_total")

    assert ingress =~ ~s(sampler_address:"sampler \\"a\\"")
    assert ingress =~ "input_snmp:7"
    refute ingress =~ "direction:ingress"

    assert egress =~ ~s(sampler_address:"sampler \\"a\\"")
    assert egress =~ "output_snmp:7"
    refute egress =~ "direction:egress"
  end

  test "p95 combines ingress and egress buckets before converting to bps" do
    iface = %{key: "k", sampler: "s", if_index: 1, bytes: 0}

    iface =
      InterfaceTraffic.with_p95(
        iface,
        [%{"timestamp" => "2026-06-21T00:00:00Z", "value" => 100}],
        [%{"timestamp" => "2026-06-21T00:00:00Z", "value" => 200}],
        60
      )

    assert iface.p95_bps == 40.0
  end
end
