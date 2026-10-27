defmodule ServiceRadarWebNGWeb.Flows.AttributedRowMappingTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.Flows.AttributedLive

  @moduletag :db_free

  test "StarRocks attribution columns fill the flow details without ocsf_payload" do
    row =
      AttributedLive.map_srql_row(%{
        "time" => ~U[2026-01-15 12:00:00Z],
        "src_endpoint_ip" => "192.0.2.10",
        "src_endpoint_port" => 53_844,
        "dst_endpoint_ip" => "198.51.100.20",
        "dst_endpoint_port" => 443,
        "protocol_num" => 6,
        "protocol_name" => "tcp",
        "bytes_total" => 1536,
        "packets_total" => 12,
        "partition" => "edge-a",
        "agent_id" => "agent-example-01",
        "pid" => 1234,
        "uid" => 101,
        "comm" => "nginx",
        "cmdline" => "/usr/sbin/nginx args:sha256:31f0e4c8",
        "container_id" => "c0ffee0123456789",
        "attribution_status" => "attributed",
        "workload_identity" => ~s({"pod_namespace":"default","pod_name":"nginx-pod","context_name":"demo-context"}),
        "public_endpoint" =>
          ~s({"namespace":"web","service_name":"storefront","exposure_class":"LoadBalancer","route_name":"storefront-route"})
      })

    assert row.attributed?
    assert row.pid == 1234
    assert row.comm == "nginx"
    assert row.cmdline == "/usr/sbin/nginx args:sha256:31f0e4c8"
    assert row.bytes == 1536
    assert row.protocol == "TCP"
    assert row.pod_namespace == "default"
    assert row.pod_name == "nginx-pod"
    assert row.context_name == "demo-context"
    assert row.agent_id == "agent-example-01"
    assert row.partition == "edge-a"
    assert row.uid == 101
    assert row.container_id == "c0ffee0123456789"
    assert row.public_endpoint_service == "storefront"
    assert row.public_endpoint_class == "LoadBalancer"
    assert row.public_endpoint_namespace == "web"
    assert row.public_endpoint_route == "storefront-route"
  end

  test "rows without pid stay unmatched" do
    row =
      AttributedLive.map_srql_row(%{
        "src_endpoint_ip" => "203.0.113.44",
        "dst_endpoint_ip" => "192.0.2.12",
        "protocol_num" => 6,
        "bytes_total" => 512,
        "attribution_status" => "unmatched"
      })

    refute row.attributed?
    assert is_nil(row.pid)
    assert is_nil(row.comm)
  end
end
