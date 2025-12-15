defmodule ServiceRadarWebNGWeb.SRQL.Catalog do
  @moduledoc false

  @entities [
    %{
      id: "devices",
      label: "Devices",
      default_time: "",
      default_sort_field: "last_seen",
      default_sort_dir: "desc",
      default_filter_field: "hostname",
      filter_fields: ["hostname", "ip", "device_id", "poller_id", "agent_id"],
      downsample: false
    },
    %{
      id: "pollers",
      label: "Pollers",
      default_time: "",
      default_sort_field: "last_seen",
      default_sort_dir: "desc",
      default_filter_field: "poller_id",
      filter_fields: ["poller_id", "status", "component_id", "registration_source"],
      downsample: false
    },
    %{
      id: "events",
      label: "Events",
      default_time: "last_7d",
      default_sort_field: "timestamp",
      default_sort_dir: "desc",
      default_filter_field: "event_type",
      filter_fields: [
        "event_type",
        "device_id",
        "poller_id",
        "agent_id",
        "severity",
        "source",
        "message"
      ],
      downsample: false
    },
    %{
      id: "logs",
      label: "Logs",
      default_time: "last_7d",
      default_sort_field: "timestamp",
      default_sort_dir: "desc",
      default_filter_field: "message",
      filter_fields: ["device_id", "poller_id", "agent_id", "severity", "source", "message"],
      downsample: false
    },
    %{
      id: "services",
      label: "Services",
      default_time: "last_7d",
      default_sort_field: "timestamp",
      default_sort_dir: "desc",
      default_filter_field: "service_type",
      filter_fields: [
        "device_id",
        "poller_id",
        "service_type",
        "service_status",
        "name",
        "port",
        "protocol"
      ],
      downsample: false
    },
    %{
      id: "interfaces",
      label: "Interfaces",
      default_time: "last_7d",
      default_sort_field: "timestamp",
      default_sort_dir: "desc",
      default_filter_field: "device_id",
      filter_fields: [
        "device_id",
        "if_name",
        "if_index",
        "mac",
        "ip_addresses",
        "admin_status",
        "oper_status"
      ],
      downsample: false
    },
    %{
      id: "timeseries_metrics",
      label: "Timeseries Metrics",
      default_time: "last_24h",
      default_sort_field: "timestamp",
      default_sort_dir: "desc",
      default_filter_field: "metric_name",
      filter_fields: [
        "poller_id",
        "agent_id",
        "metric_name",
        "metric_type",
        "device_id",
        "target_device_ip",
        "partition",
        "if_index"
      ],
      downsample: true,
      default_bucket: "5m",
      default_agg: "avg",
      default_series_field: "metric_name",
      series_fields: [
        "metric_name",
        "metric_type",
        "device_id",
        "poller_id",
        "agent_id",
        "partition",
        "target_device_ip",
        "if_index"
      ]
    },
    %{
      id: "snmp_metrics",
      label: "SNMP Metrics",
      default_time: "last_24h",
      default_sort_field: "timestamp",
      default_sort_dir: "desc",
      default_filter_field: "metric_name",
      filter_fields: [
        "poller_id",
        "agent_id",
        "metric_name",
        "device_id",
        "target_device_ip",
        "partition",
        "if_index"
      ],
      downsample: true,
      default_bucket: "5m",
      default_agg: "avg",
      default_series_field: "metric_name",
      series_fields: [
        "metric_name",
        "device_id",
        "poller_id",
        "agent_id",
        "partition",
        "target_device_ip",
        "if_index"
      ]
    },
    %{
      id: "rperf_metrics",
      label: "rPerf Metrics",
      default_time: "last_24h",
      default_sort_field: "timestamp",
      default_sort_dir: "desc",
      default_filter_field: "metric_name",
      filter_fields: [
        "poller_id",
        "agent_id",
        "metric_name",
        "device_id",
        "target_device_ip",
        "partition",
        "if_index"
      ],
      downsample: true,
      default_bucket: "5m",
      default_agg: "avg",
      default_series_field: "metric_name",
      series_fields: [
        "metric_name",
        "device_id",
        "poller_id",
        "agent_id",
        "partition",
        "target_device_ip",
        "if_index"
      ]
    },
    %{
      id: "cpu_metrics",
      label: "CPU Metrics",
      default_time: "last_24h",
      default_sort_field: "timestamp",
      default_sort_dir: "desc",
      default_filter_field: "device_id",
      filter_fields: [
        "poller_id",
        "agent_id",
        "host_id",
        "device_id",
        "partition",
        "cluster",
        "label",
        "core_id"
      ],
      downsample: true,
      default_bucket: "5m",
      default_agg: "avg",
      default_series_field: "device_id",
      series_fields: [
        "device_id",
        "host_id",
        "poller_id",
        "agent_id",
        "core_id",
        "label",
        "cluster",
        "partition"
      ]
    },
    %{
      id: "memory_metrics",
      label: "Memory Metrics",
      default_time: "last_24h",
      default_sort_field: "timestamp",
      default_sort_dir: "desc",
      default_filter_field: "device_id",
      filter_fields: ["poller_id", "agent_id", "host_id", "device_id", "partition"],
      downsample: true,
      default_bucket: "5m",
      default_agg: "avg",
      default_series_field: "device_id",
      series_fields: ["device_id", "host_id", "poller_id", "agent_id", "partition"]
    },
    %{
      id: "disk_metrics",
      label: "Disk Metrics",
      default_time: "last_24h",
      default_sort_field: "timestamp",
      default_sort_dir: "desc",
      default_filter_field: "device_id",
      filter_fields: [
        "poller_id",
        "agent_id",
        "host_id",
        "device_id",
        "partition",
        "mount_point",
        "device_name"
      ],
      downsample: true,
      default_bucket: "5m",
      default_agg: "avg",
      default_series_field: "mount_point",
      series_fields: [
        "device_id",
        "host_id",
        "poller_id",
        "agent_id",
        "partition",
        "mount_point",
        "device_name"
      ]
    },
    %{
      id: "process_metrics",
      label: "Process Metrics",
      default_time: "last_24h",
      default_sort_field: "timestamp",
      default_sort_dir: "desc",
      default_filter_field: "name",
      filter_fields: [
        "poller_id",
        "agent_id",
        "host_id",
        "device_id",
        "partition",
        "name",
        "pid",
        "status"
      ],
      downsample: true,
      default_bucket: "5m",
      default_agg: "avg",
      default_series_field: "name",
      series_fields: [
        "device_id",
        "host_id",
        "poller_id",
        "agent_id",
        "partition",
        "name",
        "pid",
        "status"
      ]
    }
  ]

  def entities, do: @entities

  def entity(id) when is_binary(id) do
    Enum.find(@entities, &(&1.id == id)) ||
      %{
        id: id,
        label: String.capitalize(id),
        default_time: "",
        default_sort_field: "timestamp",
        default_sort_dir: "desc",
        default_filter_field: "",
        filter_fields: [],
        downsample: false
      }
  end

  def entity(_), do: entity("devices")
end
