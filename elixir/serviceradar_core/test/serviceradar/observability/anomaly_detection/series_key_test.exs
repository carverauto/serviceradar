defmodule ServiceRadar.Observability.AnomalyDetection.SeriesKeyTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Observability.AnomalyDetection.SeriesKey

  describe "from_source_identity/1" do
    test "uses canonical device uid as the host component when hostname is also present" do
      key =
        SeriesKey.from_source_identity(%{
          "metric_class" => "sysmon.cpu",
          "metric_name" => "cpu.usage_percent",
          "device_id" => "device-a",
          "host_id" => "host-a",
          "agent_id" => "agent-a",
          "partition" => "prod-east",
          "tags" => %{"core_id" => "0"}
        })

      assert key == "sysmon.cpu:sysmon:cpu:prod-east:device-a:0"
      refute key =~ "host-a"
      refute key =~ "agent-a"
    end

    test "uses SNMP target ip as the host component when no canonical uid is available" do
      key =
        SeriesKey.from_source_identity(%{
          "metric_class" => "snmp.interface",
          "metric_name" => "ifHCInOctets",
          "host_id" => "polling-agent-host",
          "agent_id" => "polling-agent",
          "target_device_ip" => "192.0.2.10",
          "partition" => "prod-east",
          "if_index" => 2
        })

      assert key == "snmp.interface:prod-east:192.0.2.10:2"
      refute key =~ "polling-agent-host"
      refute key =~ "polling-agent"
    end

    test "hashes unsafe components so delimiter placement cannot collide" do
      left =
        SeriesKey.from_source_identity(%{
          "metric_class" => "sysmon.cpu",
          "metric_name" => "cpu.usage_percent",
          "agent_id" => "host:a",
          "tags" => %{"core_id" => "b"}
        })

      right =
        SeriesKey.from_source_identity(%{
          "metric_class" => "sysmon.cpu",
          "metric_name" => "cpu.usage_percent",
          "agent_id" => "host",
          "tags" => %{"core_id" => "a:b"}
        })

      refute left == right
      assert left =~ "h_"
      assert right =~ "h_"
      refute left =~ "host:a"
      refute right =~ "a:b"
    end
  end
end
