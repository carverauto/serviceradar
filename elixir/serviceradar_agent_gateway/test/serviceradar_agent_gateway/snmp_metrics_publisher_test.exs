defmodule ServiceRadarAgentGateway.SnmpMetricsPublisherTest do
  use ExUnit.Case, async: false

  alias ServiceRadarAgentGateway.SnmpMetricsPublisher

  setup do
    previous_config = Application.get_env(:serviceradar_agent_gateway, :snmp_metrics_publisher)
    previous_pid = Application.get_env(:serviceradar_agent_gateway, :snmp_metrics_publisher_test_pid)

    on_exit(fn ->
      restore_env(:snmp_metrics_publisher, previous_config)
      restore_env(:snmp_metrics_publisher_test_pid, previous_pid)
    end)

    Application.put_env(:serviceradar_agent_gateway, :snmp_metrics_publisher_test_pid, self())

    :ok
  end

  test "publishes high-capacity interface octets to metrics.snmp subjects" do
    Application.put_env(:serviceradar_agent_gateway, :snmp_metrics_publisher,
      enabled: true,
      subject_prefix: "metrics.snmp",
      connection: __MODULE__.ConnectionStub
    )

    assert :ok = SnmpMetricsPublisher.publish_snmp(snmp_status())

    assert_receive {:published, "metrics.snmp.interface.ifHCInOctets", in_payload, in_opts}
    assert_receive {:published, "metrics.snmp.interface.ifHCOutOctets", out_payload, _out_opts}
    refute_receive {:published, "metrics.snmp.interface.ifInOctets", _payload, _opts}

    assert %{
             "schema" => "serviceradar.snmp.interface_metric.v1",
             "source" => "snmp-metrics",
             "gateway_id" => "gateway-1",
             "agent_id" => "agent-1",
             "partition" => "default",
             "metric_name" => "ifHCInOctets",
             "metric_type" => "snmp",
             "value" => 1234,
             "raw_value" => "1234",
             "kind" => "sum",
             "temporality" => "cumulative",
             "is_monotonic" => true,
             "counter_width" => 64,
             "is_delta" => false,
             "target_device_ip" => "10.0.0.20",
             "if_index" => 7,
             "tags" => %{"interface_uid" => "ifindex:7", "target" => "10.0.0.20"},
             "metadata" => %{
               "oid" => ".1.3.6.1.2.1.31.1.1.1.6.7",
               "kind" => "sum",
               "temporality" => "cumulative",
               "is_monotonic" => true,
               "counter_width" => 64,
               "raw_value" => "1234"
             },
             "ingress_id" => ingress_id,
             "ingress_timestamp_unix_nano" => ingress_timestamp
           } = Jason.decode!(in_payload)

    assert ingress_id =~ uuidv8_pattern()
    assert is_integer(ingress_timestamp)
    assert ingress_headers(in_opts)

    assert %{
             "metric_name" => "ifHCOutOctets",
             "if_index" => 7,
             "target_device_ip" => "10.0.0.20"
           } = Jason.decode!(out_payload)
  end

  test "is disabled by default" do
    Application.put_env(:serviceradar_agent_gateway, :snmp_metrics_publisher,
      enabled: false,
      connection: __MODULE__.ConnectionStub
    )

    assert :disabled = SnmpMetricsPublisher.publish_snmp(snmp_status())
    refute_receive {:published, _subject, _payload, _opts}
  end

  test "reports publish failures without raising" do
    Application.put_env(:serviceradar_agent_gateway, :snmp_metrics_publisher,
      enabled: true,
      subject_prefix: "metrics.snmp",
      connection: __MODULE__.FailingConnectionStub
    )

    assert {:error, {:publish_failed, failures}} =
             SnmpMetricsPublisher.publish_snmp(snmp_status())

    assert {"metrics.snmp.interface.ifHCInOctets", :nats_down} in failures
  end

  defmodule ConnectionStub do
    @moduledoc false
    def publish(subject, payload, opts) do
      send(Application.fetch_env!(:serviceradar_agent_gateway, :snmp_metrics_publisher_test_pid), {
        :published,
        subject,
        payload,
        opts
      })

      :ok
    end
  end

  defmodule FailingConnectionStub do
    @moduledoc false
    def publish(_subject, _payload, _opts), do: {:error, :nats_down}
  end

  defp snmp_status do
    %{
      service_name: "snmp",
      service_type: "snmp",
      source: "snmp-metrics",
      agent_id: "agent-1",
      gateway_id: "gateway-1",
      partition: "default",
      timestamp: 1_765_500_000_000_000_000,
      agent_timestamp: 1_765_499_999_000_000_000,
      message:
        Jason.encode!(%{
          "results" => [
            %{
              "target" => "core-switch",
              "host" => "10.0.0.20",
              "metric" => "ifHCInOctets",
              "oid" => ".1.3.6.1.2.1.31.1.1.1.6.7",
              "value" => 1234,
              "raw_value" => "1234",
              "timestamp" => "2026-06-12T00:00:00Z",
              "data_type" => "counter",
              "scale" => 1.0,
              "delta" => false,
              "kind" => "sum",
              "temporality" => "cumulative",
              "is_monotonic" => true,
              "counter_width" => 64,
              "if_index" => 7,
              "interface_uid" => "ifindex:7"
            },
            %{
              "target" => "core-switch",
              "host" => "10.0.0.20",
              "metric" => "ifHCOutOctets::7",
              "oid" => ".1.3.6.1.2.1.31.1.1.1.10.7",
              "value" => "4321",
              "timestamp" => "2026-06-12T00:00:01Z",
              "data_type" => "counter",
              "scale" => 1.0,
              "delta" => true,
              "if_index" => "7",
              "interface_uid" => "ifindex:7"
            },
            %{
              "target" => "core-switch",
              "host" => "10.0.0.20",
              "metric" => "ifInOctets",
              "oid" => ".1.3.6.1.2.1.2.2.1.10.7",
              "value" => 111,
              "if_index" => 7
            },
            %{
              "target" => "core-switch",
              "host" => "10.0.0.20",
              "metric" => "ifHCInOctets",
              "oid" => ".1.3.6.1.2.1.31.1.1.1.6",
              "value" => 222
            }
          ]
        })
    }
  end

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_agent_gateway, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_agent_gateway, key, value)

  defp ingress_headers(opts) do
    headers =
      opts
      |> Keyword.fetch!(:headers)
      |> Map.new()

    assert headers["Sr-Ingress-Id"] =~ uuidv8_pattern()
    assert Integer.parse(headers["Sr-Ingress-Time-Unix-Nano"]) != :error
    assert headers["Sr-Agent-Id"] == "agent-1"
    assert headers["Sr-Gateway-Id"] == "gateway-1"
    assert headers["Sr-Partition"] == "default"
    assert headers["Sr-Ingest-Identity"] == "agent:agent-1"
  end

  defp uuidv8_pattern do
    ~r/^[0-9a-f]{8}-[0-9a-f]{4}-8[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
  end
end
