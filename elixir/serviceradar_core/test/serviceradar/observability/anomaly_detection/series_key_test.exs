defmodule ServiceRadar.Observability.AnomalyDetection.SeriesKeyTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Observability.AnomalyDetection.SeriesKey

  describe "from_source_identity/1" do
    test "uses canonical device_id as the host component when source_identity also carries host and agent ids" do
      source_identity = %{
        "metric_class" => "sysmon.cpu",
        "metric_name" => "cpu.usage_percent",
        "partition" => "prod-east",
        "agent_id" => "agent-ns03",
        "host_id" => "ns03",
        "device_id" => "sr:ns03",
        "host_ip" => "10.0.0.10",
        "tags" => %{"core_id" => "0"}
      }

      assert SeriesKey.from_source_identity(source_identity) ==
               key(
                 partition: "prod-east",
                 metric: "cpu.usage_percent",
                 identity: "sr:ns03",
                 tags: [{"core_id", "0"}]
               )
    end

    test "edge<->central alignment: canonical key is invariant to provisional producer hints (1.14)" do
      # The edge emits provisional producer hints (agent_id/host_id/host_ip and a
      # producer `host` tag); central re-keys from source_identity. Two views of the
      # SAME logical series that differ ONLY in those provisional fields MUST re-key
      # identically — the precondition for joining an edge-spike finding to its
      # central-seasonal verdict (the matched-resolution disposition loop, 1c).
      base = %{
        "metric_class" => "sysmon.cpu",
        "metric_name" => "cpu.usage_percent",
        "partition" => "prod-east",
        "device_id" => "sr:ns03",
        "tags" => %{"core_id" => "0", "host" => "ns03"}
      }

      edge_view =
        Map.merge(base, %{"agent_id" => "agent-A", "host_id" => "ns03", "host_ip" => "10.0.0.10"})

      central_view =
        Map.merge(base, %{"agent_id" => "agent-B", "host_id" => "ns03b", "host_ip" => "10.0.0.99"})

      k1 = SeriesKey.from_source_identity(edge_view)
      k2 = SeriesKey.from_source_identity(central_view)

      assert is_binary(k1)

      assert k1 == k2,
             "the same logical series must re-key identically regardless of provisional producer hints"
    end

    test "uses the same canonical device_id host component for SNMP target metrics" do
      source_identity = %{
        "metric_class" => "snmp",
        "metric_name" => "ifHCInOctets",
        "partition" => "prod-east",
        "agent_id" => "agent-ns03",
        "host_id" => "ns03",
        "device_id" => "sr:ns03",
        "target_device_ip" => "10.0.0.20",
        "if_index" => 7,
        "tags" => %{"interface_uid" => "ifindex:7"}
      }

      assert SeriesKey.from_source_identity(source_identity) ==
               key(
                 partition: "prod-east",
                 metric: "ifHCInOctets",
                 identity: "sr:ns03",
                 if_index: 7
               )
    end

    test "uses target_device_ip before the polling host for remote SNMP target metrics" do
      source_identity = %{
        "metric_class" => "snmp",
        "metric_name" => "ifHCInOctets",
        "partition" => "prod-east",
        "agent_id" => "agent-ns03",
        "host_id" => "ns03",
        "target_device_ip" => "10.0.0.20",
        "if_index" => 7,
        "tags" => %{"interface_uid" => "ifindex:7"}
      }

      assert SeriesKey.from_source_identity(source_identity) ==
               key(
                 partition: "prod-east",
                 metric: "ifHCInOctets",
                 identity: "10.0.0.20",
                 if_index: 7
               )
    end

    test "keeps different SNMP counters on the same target interface isolated" do
      base = %{
        "metric_class" => "snmp",
        "partition" => "prod-east",
        "target_device_ip" => "10.0.0.20",
        "if_index" => 7
      }

      in_octets = SeriesKey.from_source_identity(Map.put(base, "metric_name", "ifInOctets"))
      out_octets = SeriesKey.from_source_identity(Map.put(base, "metric_name", "ifOutOctets"))
      in_packets = SeriesKey.from_source_identity(Map.put(base, "metric_name", "ifInUcastPkts"))

      refute in_octets == out_octets
      refute in_octets == in_packets
      refute out_octets == in_packets

      assert in_octets =~ "metric=#{hex("ifInOctets")}"
      assert out_octets =~ "metric=#{hex("ifOutOctets")}"
      assert in_packets =~ "metric=#{hex("ifInUcastPkts")}"
    end

    test "falls back to host_id when no canonical device_id is available" do
      source_identity = %{
        "metric_class" => "sysmon.memory",
        "metric_name" => "memory.used_percent",
        "agent_id" => "agent-ns03",
        "host_id" => "ns03"
      }

      assert SeriesKey.from_source_identity(source_identity) ==
               key(partition: "default", metric: "memory.used_percent", identity: "ns03")
    end

    test "uses default partition when trusted and producer partitions are absent or blank" do
      source_identity = %{
        "metric_class" => "sysmon.memory",
        "metric_name" => "memory.used_percent",
        "partition" => "",
        "partition_id" => nil,
        "host_id" => "ns03"
      }

      assert SeriesKey.from_source_identity(source_identity, partition_id: nil) ==
               key(partition: "default", metric: "memory.used_percent", identity: "ns03")
    end

    test "trusted partition option overrides producer supplied partition" do
      source_identity = %{
        "metric_class" => "sysmon.cpu",
        "metric_name" => "cpu.usage_percent",
        "partition" => "spoofed",
        "device_id" => "sr:ns03"
      }

      key = SeriesKey.from_source_identity(source_identity, partition_id: "prod-east")

      assert key =~ "partition=#{hex("prod-east")}"
      refute key =~ hex("spoofed")
    end

    test "same source identity stays isolated across partitions" do
      source_identity = %{
        "metric_class" => "snmp.if_octets",
        "metric_name" => "ifHCInOctets",
        "target_device_ip" => "10.0.0.20",
        "if_index" => 7,
        "tags" => %{"if_alias" => "core-uplink"}
      }

      prod_key = SeriesKey.from_source_identity(source_identity, partition_id: "prod-east")
      lab_key = SeriesKey.from_source_identity(source_identity, partition_id: "lab-west")

      refute prod_key == lab_key
      assert prod_key =~ "partition=#{hex("prod-east")}"
      assert lab_key =~ "partition=#{hex("lab-west")}"
      assert prod_key =~ "identity=#{hex("10.0.0.20")}"
      assert lab_key =~ "identity=#{hex("10.0.0.20")}"
      assert prod_key =~ "metric=#{hex("ifHCInOctets")}"
      assert lab_key =~ "metric=#{hex("ifHCInOctets")}"
    end

    test "free-form delimiters cannot collide or leak raw into canonical keys" do
      first = %{
        "metric_class" => "sysmon.cpu",
        "metric_name" => "cpu.usage_percent",
        "partition" => "prod:east",
        "device_id" => "host:a",
        "tags" => %{"core_id" => "b"}
      }

      second = %{
        "metric_class" => "sysmon.cpu",
        "metric_name" => "cpu.usage_percent",
        "partition" => "prod",
        "device_id" => "host",
        "tags" => %{"core_id" => "east:host:a:b"}
      }

      first_key = SeriesKey.from_source_identity(first)
      second_key = SeriesKey.from_source_identity(second)

      refute first_key == second_key
      refute first_key =~ "prod:east"
      refute first_key =~ "host:a"
      refute second_key =~ "east:host:a:b"
    end

    test "component names and hex values make delimiter-shaped producer values collision resistant" do
      split_components = %{
        "metric_class" => "sysmon.cpu",
        "metric_name" => "cpu.usage_percent",
        "partition" => "tenant:a",
        "device_id" => "host",
        "tags" => %{"core_id" => "b:c"}
      }

      shifted_delimiters = %{
        "metric_class" => "sysmon.cpu",
        "metric_name" => "cpu.usage_percent",
        "partition" => "tenant",
        "device_id" => "a:host:b",
        "tags" => %{"core_id" => "c"}
      }

      first_key = SeriesKey.from_source_identity(split_components)
      second_key = SeriesKey.from_source_identity(shifted_delimiters)

      refute first_key == second_key
      assert first_key =~ "partition=#{hex("tenant:a")}"
      assert first_key =~ "identity=#{hex("host")}"
      assert first_key =~ "tag_#{hex("core_id")}=#{hex("b:c")}"
      assert second_key =~ "partition=#{hex("tenant")}"
      assert second_key =~ "identity=#{hex("a:host:b")}"
      assert second_key =~ "tag_#{hex("core_id")}=#{hex("c")}"

      for raw <- ["tenant:a", "a:host:b", "b:c"] do
        refute first_key =~ raw
        refute second_key =~ raw
      end
    end

    test "byte-parity fixture matches the edge fallback key for host cpu series" do
      source_identity = %{
        "metric_class" => "sysmon.cpu",
        "metric_name" => "cpu.usage_percent",
        "partition" => "demo",
        "device_id" => "device-a",
        "tags" => %{
          "host" => "device-a",
          "core_id" => "3",
          "label" => "cpu3",
          "pid" => "1234",
          "start_time" => "1812456000",
          "zone" => "rack-a"
        }
      }

      assert SeriesKey.from_source_identity(source_identity) ==
               key(
                 partition: "demo",
                 identity: "device-a",
                 metric: "cpu.usage_percent",
                 tags: [{"core_id", "3"}, {"label", "cpu3"}, {"zone", "rack-a"}]
               )
    end

    test "byte-parity fixture matches the edge fallback key for SNMP interface series" do
      source_identity = %{
        "metric_class" => "snmp.interface",
        "metric_name" => "ifHCInOctets",
        "partition" => "net",
        "target_device_ip" => "192.168.1.5",
        "interface_uid" => "if-uid-7",
        "if_index" => 7,
        "tags" => %{
          "mount_point" => "ignored?",
          "alpha" => "z",
          "ifName" => "Gi0/1",
          "interface_uid" => "excluded-from-tags"
        }
      }

      assert SeriesKey.from_source_identity(source_identity) ==
               key(
                 partition: "net",
                 identity: "192.168.1.5",
                 metric: "ifHCInOctets",
                 interface_uid: "if-uid-7",
                 if_index: 7,
                 tags: [
                   {"mount_point", "ignored?"},
                   {"alpha", "z"},
                   {"ifName", "Gi0/1"}
                 ]
               )
    end
  end

  defp key(opts) do
    [
      "v2",
      component("partition", Keyword.fetch!(opts, :partition)),
      component("identity", Keyword.fetch!(opts, :identity)),
      component("metric", Keyword.fetch!(opts, :metric)),
      component("interface_uid", Keyword.get(opts, :interface_uid))
    ]
    |> Enum.reject(&is_nil/1)
    |> Kernel.++(if_index_component(Keyword.get(opts, :if_index)))
    |> Kernel.++(tag_components(Keyword.get(opts, :tags, [])))
    |> Enum.join("|")
  end

  defp component(_name, nil), do: nil
  defp component(name, value), do: "#{name}=#{hex(value)}"

  defp tag_components(tags),
    do: Enum.map(tags, fn {key, value} -> "tag_#{hex(key)}=#{hex(value)}" end)

  defp if_index_component(nil), do: []
  defp if_index_component(value), do: [component("if_index", value)]
  defp hex(value), do: value |> to_string() |> Base.encode16(case: :lower)
end
