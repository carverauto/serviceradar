defmodule ServiceRadarAgentGateway.SysmonMetricsPublisherTest do
  use ExUnit.Case, async: false

  alias ServiceRadarAgentGateway.SysmonMetricsPublisher

  setup do
    previous_config = Application.get_env(:serviceradar_agent_gateway, :sysmon_metrics_publisher)
    previous_pid = Application.get_env(:serviceradar_agent_gateway, :sysmon_metrics_publisher_test_pid)

    on_exit(fn ->
      restore_env(:sysmon_metrics_publisher, previous_config)
      restore_env(:sysmon_metrics_publisher_test_pid, previous_pid)
    end)

    Application.put_env(:serviceradar_agent_gateway, :sysmon_metrics_publisher_test_pid, self())

    :ok
  end

  test "publishes populated sysmon families to metrics.sysmon subjects" do
    Application.put_env(:serviceradar_agent_gateway, :sysmon_metrics_publisher,
      enabled: true,
      subject_prefix: "metrics.sysmon",
      connection: __MODULE__.ConnectionStub
    )

    assert :ok = SysmonMetricsPublisher.publish_sysmon(sysmon_status())

    assert_receive {:published, "metrics.sysmon.cpu", cpu_payload}
    assert_receive {:published, "metrics.sysmon.memory", memory_payload}
    assert_receive {:published, "metrics.sysmon.disk", disk_payload}
    refute_receive {:published, "metrics.sysmon.process", _payload}

    assert %{"metric_family" => "cpu", "sample" => %{"host_id" => "host-1"}} =
             Jason.decode!(cpu_payload)

    assert %{"metric_family" => "memory"} = Jason.decode!(memory_payload)
    assert %{"metric_family" => "disk"} = Jason.decode!(disk_payload)
  end

  test "preserves future downsample window metadata on published samples" do
    Application.put_env(:serviceradar_agent_gateway, :sysmon_metrics_publisher,
      enabled: true,
      subject_prefix: "metrics.sysmon",
      connection: __MODULE__.ConnectionStub
    )

    assert :ok = SysmonMetricsPublisher.publish_sysmon(sysmon_status_with_downsample_metadata())

    assert_receive {:published, "metrics.sysmon.cpu", cpu_payload}

    assert %{
             "sample" => %{
               "downsample_window" => %{
                 "start" => "2026-06-12T00:00:00Z",
                 "end" => "2026-06-12T00:01:00Z"
               },
               "downsample_mode" => %{"cpu" => "avg", "memory" => "avg"},
               "sample_count" => 6
             }
           } = Jason.decode!(cpu_payload)
  end

  test "is disabled by default" do
    Application.put_env(:serviceradar_agent_gateway, :sysmon_metrics_publisher,
      enabled: false,
      connection: __MODULE__.ConnectionStub
    )

    assert :disabled = SysmonMetricsPublisher.publish_sysmon(sysmon_status())
    refute_receive {:published, _subject, _payload}
  end

  test "reports publish failures without raising" do
    Application.put_env(:serviceradar_agent_gateway, :sysmon_metrics_publisher,
      enabled: true,
      subject_prefix: "metrics.sysmon",
      connection: __MODULE__.FailingConnectionStub
    )

    assert {:error, {:publish_failed, failures}} =
             SysmonMetricsPublisher.publish_sysmon(sysmon_status())

    assert {"metrics.sysmon.cpu", :nats_down} in failures
  end

  defmodule ConnectionStub do
    @moduledoc false
    def publish(subject, payload, _opts) do
      send(Application.fetch_env!(:serviceradar_agent_gateway, :sysmon_metrics_publisher_test_pid), {
        :published,
        subject,
        payload
      })

      :ok
    end
  end

  defmodule FailingConnectionStub do
    @moduledoc false
    def publish(_subject, _payload, _opts), do: {:error, :nats_down}
  end

  defp sysmon_status do
    %{
      service_name: "sysmon",
      service_type: "sysmon",
      source: "sysmon-metrics",
      agent_id: "agent-1",
      gateway_id: "gateway-1",
      partition: "default",
      timestamp: 1_765_500_000_000_000_000,
      agent_timestamp: 1_765_499_999_000_000_000,
      message:
        Jason.encode!(%{
          "available" => true,
          "response_time" => 0,
          "status" => %{
            "timestamp" => "2026-06-12T00:00:00Z",
            "host_id" => "host-1",
            "host_ip" => "10.0.0.10",
            "agent_id" => "agent-1",
            "cpus" => [%{"core_id" => 0, "usage_percent" => 12.5}],
            "clusters" => [],
            "disks" => [%{"mount_point" => "/", "used_bytes" => 10, "total_bytes" => 100}],
            "memory" => %{"used_bytes" => 50, "total_bytes" => 100},
            "network" => [],
            "processes" => []
          }
        })
    }
  end

  defp sysmon_status_with_downsample_metadata do
    put_in(
      sysmon_status(),
      [:message],
      Jason.encode!(%{
        "available" => true,
        "response_time" => 0,
        "status" => %{
          "timestamp" => "2026-06-12T00:01:00Z",
          "host_id" => "host-1",
          "host_ip" => "10.0.0.10",
          "agent_id" => "agent-1",
          "cpus" => [%{"core_id" => 0, "usage_percent" => 12.5}],
          "clusters" => [],
          "disks" => [],
          "memory" => %{"used_bytes" => 50, "total_bytes" => 100},
          "network" => [],
          "processes" => [],
          "downsample_window" => %{
            "start" => "2026-06-12T00:00:00Z",
            "end" => "2026-06-12T00:01:00Z"
          },
          "downsample_mode" => %{"cpu" => "avg", "memory" => "avg"},
          "sample_count" => 6
        }
      })
    )
  end

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_agent_gateway, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_agent_gateway, key, value)
end
