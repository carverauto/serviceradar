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
                 class: "sysmon",
                 family: "cpu",
                 identity: "sr:ns03",
                 tags: [{"core_id", "0"}]
               )
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
               key(partition: "prod-east", class: "snmp", identity: "sr:ns03", if_index: 7)
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
               key(partition: "prod-east", class: "snmp", identity: "10.0.0.20", if_index: 7)
    end

    test "falls back to host_id when no canonical device_id is available" do
      source_identity = %{
        "metric_class" => "sysmon.memory",
        "metric_name" => "memory.used_percent",
        "agent_id" => "agent-ns03",
        "host_id" => "ns03"
      }

      assert SeriesKey.from_source_identity(source_identity) ==
               key(partition: "default", class: "sysmon", family: "memory", identity: "ns03")
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
  end

  defp key(opts) do
    [
      "v2",
      component("partition", Keyword.fetch!(opts, :partition)),
      component("class", Keyword.fetch!(opts, :class)),
      component("family", Keyword.get(opts, :family)),
      component("identity", Keyword.fetch!(opts, :identity))
    ]
    |> Enum.reject(&is_nil/1)
    |> Kernel.++(tag_components(Keyword.get(opts, :tags, [])))
    |> Kernel.++(if_index_component(Keyword.get(opts, :if_index)))
    |> Enum.join(":")
  end

  defp component(_name, nil), do: nil
  defp component(name, value), do: "#{name}=#{hex(value)}"

  defp tag_components(tags),
    do: Enum.map(tags, fn {key, value} -> "tag_#{hex(key)}=#{hex(value)}" end)

  defp if_index_component(nil), do: []
  defp if_index_component(value), do: [component("if_index", value)]
  defp hex(value), do: value |> to_string() |> Base.encode16(case: :lower)
end
