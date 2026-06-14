defmodule ServiceRadarAgentGateway.PluginMetricsPublisherTest do
  use ExUnit.Case, async: false

  alias ServiceRadarAgentGateway.PluginMetricsPublisher

  setup do
    previous_config = Application.get_env(:serviceradar_agent_gateway, :plugin_metrics_publisher)

    previous_pid =
      Application.get_env(:serviceradar_agent_gateway, :plugin_metrics_publisher_test_pid)

    on_exit(fn ->
      restore_env(:plugin_metrics_publisher, previous_config)
      restore_env(:plugin_metrics_publisher_test_pid, previous_pid)
    end)

    Application.put_env(:serviceradar_agent_gateway, :plugin_metrics_publisher_test_pid, self())

    :ok
  end

  test "publishes structured plugin result metrics as generic scalar metrics" do
    Application.put_env(:serviceradar_agent_gateway, :plugin_metrics_publisher,
      enabled: true,
      subject_prefix: "metrics.timeseries",
      connection: __MODULE__.ConnectionStub
    )

    assert :ok = PluginMetricsPublisher.publish_plugin_metrics(plugin_status())

    assert_receive {:published, "metrics.timeseries.cpu.proxmox_guest_cpu_ratio_max", payload, opts}

    assert %{
             "schema" => "serviceradar.metric.v1",
             "source" => "plugin-result",
             "timestamp" => "2026-06-13T18:20:00Z",
             "gateway_id" => "gateway-1",
             "agent_id" => "agent-1",
             "partition" => "default",
             "metric_name" => "proxmox_guest_cpu_ratio_max",
             "metric_type" => "cpu",
             "value" => 0.91,
             "unit" => "ratio",
             "tags" => %{
               "producer_id" => "proxmox-inventory",
               "producer_kind" => "plugin_result",
               "service_type" => "wasm-plugin"
             },
             "metadata" => %{
               "crit" => 0.9,
               "original_metric_name" => "proxmox_guest_cpu_ratio_max",
               "producer_id" => "proxmox-inventory",
               "producer_kind" => "plugin_result",
               "service_name" => "proxmox-inventory",
               "status" => "WARNING",
               "summary" => "resource pressure",
               "warn" => 0.8
             },
             "ingress_id" => ingress_id,
             "ingress_timestamp_unix_nano" => ingress_timestamp
           } = Jason.decode!(payload)

    assert ingress_id =~ uuidv8_pattern()
    assert is_integer(ingress_timestamp)
    assert ingress_headers(opts)
  end

  test "skips plugin results without structured metrics" do
    Application.put_env(:serviceradar_agent_gateway, :plugin_metrics_publisher,
      enabled: true,
      subject_prefix: "metrics.timeseries",
      connection: __MODULE__.ConnectionStub
    )

    assert :ok =
             PluginMetricsPublisher.publish_plugin_metrics(%{
               plugin_status()
               | message: Jason.encode!(%{"status" => "OK", "summary" => "inventory only"})
             })

    refute_receive {:published, _subject, _payload, _opts}
  end

  test "is disabled by default" do
    Application.put_env(:serviceradar_agent_gateway, :plugin_metrics_publisher,
      enabled: false,
      connection: __MODULE__.ConnectionStub
    )

    assert :disabled = PluginMetricsPublisher.publish_plugin_metrics(plugin_status())
    refute_receive {:published, _subject, _payload, _opts}
  end

  test "reports publish failures without raising" do
    Application.put_env(:serviceradar_agent_gateway, :plugin_metrics_publisher,
      enabled: true,
      subject_prefix: "metrics.timeseries",
      connection: __MODULE__.FailingConnectionStub
    )

    assert {:error, {:publish_failed, failures}} =
             PluginMetricsPublisher.publish_plugin_metrics(plugin_status())

    assert {"metrics.timeseries.cpu.proxmox_guest_cpu_ratio_max", :nats_down} in failures
  end

  test "carries producer-declared OTLP-grade semantics into the v2 envelope" do
    Application.put_env(:serviceradar_agent_gateway, :plugin_metrics_publisher,
      enabled: true,
      subject_prefix: "metrics.timeseries",
      connection: __MODULE__.ConnectionStub
    )

    status = %{
      plugin_status()
      | message:
          Jason.encode!(%{
            "status" => "OK",
            "metrics" => [
              %{
                "name" => "net_bytes_total",
                "value" => 4_000_000_000,
                "unit" => "By",
                "kind" => "sum",
                "temporality" => "cumulative",
                "is_monotonic" => true
              }
            ]
          })
    }

    assert :ok = PluginMetricsPublisher.publish_plugin_metrics(status)
    assert_receive {:published, _subject, payload, _opts}

    assert %{
             "schema" => "serviceradar.metric.v1",
             "schema_version" => 2,
             "kind" => "sum",
             "temporality" => "cumulative",
             "is_monotonic" => true
           } = Jason.decode!(payload)
  end

  test "stamps schema_version 1 for legacy flat plugin metrics" do
    Application.put_env(:serviceradar_agent_gateway, :plugin_metrics_publisher,
      enabled: true,
      subject_prefix: "metrics.timeseries",
      connection: __MODULE__.ConnectionStub
    )

    assert :ok = PluginMetricsPublisher.publish_plugin_metrics(plugin_status())
    assert_receive {:published, _subject, payload, _opts}
    decoded = Jason.decode!(payload)
    assert decoded["schema_version"] == 1

    # Legacy v1 envelopes must be genuinely absent the OTLP-grade keys, not carry
    # them as JSON null (fj #3788 REC1 review).
    for key <- ["kind", "temporality", "is_monotonic", "start_time_unix_nano"] do
      refute Map.has_key?(decoded, key)
    end
  end

  defmodule ConnectionStub do
    @moduledoc false
    def publish(subject, payload, opts) do
      send(
        Application.fetch_env!(:serviceradar_agent_gateway, :plugin_metrics_publisher_test_pid),
        {
          :published,
          subject,
          payload,
          opts
        }
      )

      :ok
    end
  end

  defmodule FailingConnectionStub do
    @moduledoc false
    def publish(_subject, _payload, _opts), do: {:error, :nats_down}
  end

  defp plugin_status do
    %{
      service_name: "proxmox-inventory",
      service_type: "wasm-plugin",
      source: "plugin-result",
      agent_id: "agent-1",
      gateway_id: "gateway-1",
      partition: "default",
      timestamp: 1_765_500_000_000_000_000,
      agent_timestamp: 1_765_499_999_000_000_000,
      message:
        Jason.encode!(%{
          "status" => "WARNING",
          "summary" => "resource pressure",
          "observed_at" => "2026-06-13T18:20:00Z",
          "metrics" => [
            %{
              "name" => "proxmox_guest_cpu_ratio_max",
              "value" => 0.91,
              "unit" => "ratio",
              "warn" => 0.8,
              "crit" => 0.9
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
