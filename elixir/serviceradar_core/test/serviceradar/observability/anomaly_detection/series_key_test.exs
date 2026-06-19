defmodule ServiceRadar.Observability.AnomalyDetection.SeriesKeyTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Observability.AnomalyDetection.SeriesKey

  describe "from_source_identity/1" do
    test "uses canonical device_id as the host component when source_identity also carries host and agent ids" do
      source_identity = %{
        "metric_class" => "sysmon.cpu",
        "metric_name" => "cpu.usage_percent",
        "agent_id" => "agent-ns03",
        "host_id" => "ns03",
        "device_id" => "sr:ns03",
        "host_ip" => "10.0.0.10",
        "tags" => %{"core_id" => "0"}
      }

      assert SeriesKey.from_source_identity(source_identity) == "sysmon:cpu:sr:ns03:0"
    end

    test "uses the same canonical device_id host component for SNMP target metrics" do
      source_identity = %{
        "metric_class" => "snmp",
        "metric_name" => "ifHCInOctets",
        "agent_id" => "agent-ns03",
        "host_id" => "ns03",
        "device_id" => "sr:ns03",
        "target_device_ip" => "10.0.0.20",
        "if_index" => 7,
        "tags" => %{"interface_uid" => "ifindex:7"}
      }

      assert SeriesKey.from_source_identity(source_identity) == "snmp:sr:ns03:7"
    end

    test "falls back to host_id when no canonical device_id is available" do
      source_identity = %{
        "metric_class" => "sysmon.memory",
        "metric_name" => "memory.used_percent",
        "agent_id" => "agent-ns03",
        "host_id" => "ns03"
      }

      assert SeriesKey.from_source_identity(source_identity) == "sysmon:memory:ns03"
    end
  end
end
