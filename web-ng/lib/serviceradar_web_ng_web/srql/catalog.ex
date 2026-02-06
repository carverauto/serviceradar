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
      filter_fields: [
        "hostname",
        "ip",
        "uid",
        "gateway_id",
        "agent_id",
        "is_available",
        "is_managed",
        "is_compliant",
        "is_trusted",
        "type_id",
        "type",
        "vendor_name",
        "discovery_sources",
        "tags",
        "include_deleted"
      ],
      boolean_fields: [
        "is_available",
        "is_managed",
        "is_compliant",
        "is_trusted",
        "include_deleted"
      ],
      # Fields backed by array columns - builder will always use list syntax for these
      array_fields: ["discovery_sources", "tags"],
      # Fields that support GROUP BY in stats queries (stats:count() as count by <field>)
      stats_fields: ["type", "vendor_name", "risk_level", "is_available", "gateway_id"],
      downsample: false
    },
    %{
      id: "gateways",
      label: "Gateways",
      route: "/gateways",
      default_time: "",
      default_sort_field: "last_seen",
      default_sort_dir: "desc",
      default_filter_field: "id",
      filter_fields: ["id", "status", "component_id", "registration_source", "is_healthy"],
      boolean_fields: ["is_healthy"],
      downsample: false
    },
    %{
      id: "events",
      label: "Events",
      route: "/events",
      default_time: "last_7d",
      default_sort_field: "timestamp",
      default_sort_dir: "desc",
      default_filter_field: "message",
      filter_fields: [
        "activity_name",
        "activity_id",
        "class_uid",
        "category_uid",
        "type_uid",
        "severity",
        "severity_id",
        "log_level",
        "log_name",
        "log_provider",
        "status",
        "status_id",
        "status_code",
        "status_detail",
        "trace_id",
        "span_id",
        "message",
        "short_message"
      ],
      downsample: false
    },
    %{
      id: "alerts",
      label: "Alerts",
      route: "/alerts",
      default_time: "last_7d",
      default_sort_field: "timestamp",
      default_sort_dir: "desc",
      default_filter_field: "title",
      filter_fields: [
        "title",
        "status",
        "severity",
        "source_type",
        "source_id",
        "device_uid",
        "agent_uid"
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
      filter_fields: ["uid", "gateway_id", "agent_id", "severity", "source", "message"],
      downsample: false
    },
    %{
      id: "flows",
      label: "NetFlow",
      route: "/observability",
      default_time: "last_24h",
      default_sort_field: "time",
      default_sort_dir: "desc",
      default_filter_field: "src_endpoint_ip",
      filter_fields: [
        "src_endpoint_ip",
        "dst_endpoint_ip",
        "src_port",
        "dst_port",
        "protocol_name",
        "protocol_num",
        "sampler_address"
      ],
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
        "service_id",
        "gateway_id",
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
        "device_id",
        "if_name",
        "if_index",
        "mac",
        "ip_addresses",
        "admin_status",
        "oper_status",
        "favorited",
        "metrics_enabled"
      ],
      boolean_fields: ["favorited", "metrics_enabled"],
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
        "gateway_id",
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
        "gateway_id",
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
        "gateway_id",
        "agent_id",
        "metric_name",
        "uid",
        "device_id",
        "target_device_ip",
        "partition",
        "if_index"
      ],
      downsample: true,
      default_bucket: "5m",
      # Use rate aggregation by default for SNMP metrics (byte counters need rate calculation)
      default_agg: "rate",
      default_series_field: "metric_name",
      series_fields: [
        "metric_name",
        "uid",
        "gateway_id",
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
        "gateway_id",
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
        "gateway_id",
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
        "gateway_id",
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
        "gateway_id",
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
      filter_fields: ["gateway_id", "agent_id", "host_id", "uid", "partition"],
      downsample: true,
      default_bucket: "5m",
      default_agg: "avg",
      default_series_field: "uid",
      series_fields: ["uid", "host_id", "gateway_id", "agent_id", "partition"]
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
        "gateway_id",
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
        "gateway_id",
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
        "gateway_id",
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
        "gateway_id",
        "agent_id",
        "partition",
        "name",
        "pid",
        "status"
      ]
    },
    %{
      id: "interface_settings",
      label: "Interface Settings",
      route: "/devices",
      default_time: "",
      default_sort_field: "updated_at",
      default_sort_dir: "desc",
      default_filter_field: "device_id",
      filter_fields: [
        "device_id",
        "interface_uid",
        "favorited",
        "metrics_enabled",
        "threshold_enabled",
        "tags"
      ],
      boolean_fields: ["favorited", "metrics_enabled", "threshold_enabled"],
      downsample: false
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
