defmodule ServiceRadarWebNGWeb.Flows.AttributedRowMappingTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.Flows.AttributedLive

  @moduletag :db_free

  test "StarRocks top-level pid/comm mark the row attributed without ocsf_payload" do
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
        "pid" => 1234,
        "comm" => "nginx",
        "cmdline" => "/usr/sbin/nginx args:sha256:31f0e4c8",
        "attribution_status" => "attributed",
        "workload_identity" => ~s({"pod_namespace":"default","pod_name":"nginx-pod","context_name":"demo-context"})
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
  end

  test "CNPG ocsf_payload attribution remains the fallback" do
    row =
      AttributedLive.map_srql_row(%{
        "time" => ~U[2026-01-15 12:00:00Z],
        "src_endpoint_ip" => "192.0.2.11",
        "dst_endpoint_ip" => "198.51.100.21",
        "protocol_num" => 17,
        "bytes_total" => 2048,
        "ocsf_payload" => %{
          "attribution" => %{
            "pid" => "2222",
            "comm" => "dns-client",
            "redacted_cmdline" => "/usr/bin/dig args:sha256:765d0bcf"
          }
        }
      })

    assert row.attributed?
    assert row.pid == 2222
    assert row.comm == "dns-client"
    assert row.cmdline == "/usr/bin/dig args:sha256:765d0bcf"
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
