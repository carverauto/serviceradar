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
      filter_fields: ["hostname", "ip", "device_id", "poller_id", "agent_id"]
    },
    %{
      id: "pollers",
      label: "Pollers",
      default_time: "",
      default_sort_field: "last_seen",
      default_sort_dir: "desc",
      default_filter_field: "poller_id",
      filter_fields: ["poller_id", "status", "component_id", "registration_source"]
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
      ]
    },
    %{
      id: "logs",
      label: "Logs",
      default_time: "last_7d",
      default_sort_field: "timestamp",
      default_sort_dir: "desc",
      default_filter_field: "message",
      filter_fields: ["device_id", "poller_id", "agent_id", "severity", "source", "message"]
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
      ]
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
        filter_fields: []
      }
  end

  def entity(_), do: entity("devices")
end
