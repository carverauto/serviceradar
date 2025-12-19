defmodule ServiceRadarWebNGWeb.SRQL.Catalog do
  @moduledoc false

  @entities [
    %{
      id: "devices",
      label: "Devices",
      route: "/devices",
      default_time: "",
      default_sort_field: "last_seen",
      default_sort_dir: "desc",
      default_filter_field: "hostname",
      filter_fields: ["hostname", "ip", "uid", "poller_id", "agent_id"],
      downsample: false
    },
    %{
      id: "pollers",
      label: "Pollers",
      route: "/pollers",
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
      route: "/events",
      default_time: "last_7d",
      default_sort_field: "timestamp",
      default_sort_dir: "desc",
      default_filter_field: "event_type",
      filter_fields: [
        "event_type",
        "uid",
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
      route: "/logs",
      default_time: "last_7d",
      default_sort_field: "timestamp",
      default_sort_dir: "desc",
      default_filter_field: "message",
      filter_fields: ["uid", "poller_id", "agent_id", "severity", "source", "message"],
      downsample: false
    },
    %{
      id: "services",
      label: "Services",
      route: "/services",
      default_time: "last_7d",
      default_sort_field: "timestamp",
      default_sort_dir: "desc",
      default_filter_field: "service_type",
      filter_fields: [
        "uid",
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
      route: "/interfaces",
      default_time: "last_7d",
      default_sort_field: "timestamp",
      default_sort_dir: "desc",
      default_filter_field: "uid",
      filter_fields: [
        "uid",
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
      route: "/dashboard",
      default_time: "last_24h",
      default_sort_field: "timestamp",
      default_sort_dir: "desc",
      default_filter_field: "metric_name",
      filter_fields: [
        "poller_id",
        "agent_id",
        "metric_name",
        "metric_type",
        "uid",
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
        "uid",
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
      route: "/dashboard",
      default_time: "last_24h",
      default_sort_field: "timestamp",
      default_sort_dir: "desc",
      default_filter_field: "metric_name",
      filter_fields: [
        "poller_id",
        "agent_id",
        "metric_name",
        "uid",
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
        "uid",
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
      route: "/dashboard",
      default_time: "last_24h",
      default_sort_field: "timestamp",
      default_sort_dir: "desc",
      default_filter_field: "metric_name",
      filter_fields: [
        "poller_id",
        "agent_id",
        "metric_name",
        "uid",
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
        "uid",
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
      route: "/dashboard",
      default_time: "last_24h",
      default_sort_field: "timestamp",
      default_sort_dir: "desc",
      default_filter_field: "uid",
      filter_fields: [
        "poller_id",
        "agent_id",
        "host_id",
        "uid",
        "partition",
        "cluster",
        "label",
        "core_id"
      ],
      downsample: true,
      default_bucket: "5m",
      default_agg: "avg",
      default_series_field: "uid",
      series_fields: [
        "uid",
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
      route: "/dashboard",
      default_time: "last_24h",
      default_sort_field: "timestamp",
      default_sort_dir: "desc",
      default_filter_field: "uid",
      filter_fields: ["poller_id", "agent_id", "host_id", "uid", "partition"],
      downsample: true,
      default_bucket: "5m",
      default_agg: "avg",
      default_series_field: "uid",
      series_fields: ["uid", "host_id", "poller_id", "agent_id", "partition"]
    },
    %{
      id: "disk_metrics",
      label: "Disk Metrics",
      route: "/dashboard",
      default_time: "last_24h",
      default_sort_field: "timestamp",
      default_sort_dir: "desc",
      default_filter_field: "uid",
      filter_fields: [
        "poller_id",
        "agent_id",
        "host_id",
        "uid",
        "partition",
        "mount_point",
        "device_name"
      ],
      downsample: true,
      default_bucket: "5m",
      default_agg: "avg",
      default_series_field: "mount_point",
      series_fields: [
        "uid",
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
      route: "/dashboard",
      default_time: "last_24h",
      default_sort_field: "timestamp",
      default_sort_dir: "desc",
      default_filter_field: "name",
      filter_fields: [
        "poller_id",
        "agent_id",
        "host_id",
        "uid",
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
        "uid",
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
