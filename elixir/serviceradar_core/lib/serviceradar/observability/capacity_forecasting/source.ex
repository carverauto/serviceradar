defmodule ServiceRadar.Observability.CapacityForecasting.Source do
  @moduledoc """
  Forecast source definitions for aggregate SRQL queries.
  """

  @default_time_range "last_180d"
  @default_limit 50_000

  @type t :: %__MODULE__{
          name: String.t(),
          resource_type: String.t(),
          metric_class: String.t(),
          metric_name: String.t(),
          query: String.t(),
          value_field: String.t(),
          bucket_field: String.t(),
          key_fields: [String.t()],
          label_fields: [String.t()],
          threshold: float() | nil,
          model: String.t()
        }

  defstruct name: nil,
            resource_type: nil,
            metric_class: nil,
            metric_name: nil,
            query: nil,
            value_field: "value",
            bucket_field: "bucket",
            key_fields: [],
            label_fields: [],
            threshold: nil,
            model: "auto"

  @spec defaults(keyword()) :: [t()]
  def defaults(opts \\ []) do
    time_range = Keyword.get(opts, :time_range, @default_time_range)
    limit = Keyword.get(opts, :limit, @default_limit)

    [
      %__MODULE__{
        name: "cpu_usage",
        resource_type: "cpu",
        metric_class: "cpu",
        metric_name: "usage_percent",
        query:
          "in:cpu_metrics time:#{time_range} bucket:1h stats:avg(usage_percent) as avg_usage_percent by bucket,device_id,host_id sort:bucket:asc limit:#{limit}",
        value_field: "avg_usage_percent",
        key_fields: ["device_id", "host_id"],
        label_fields: ["host_id", "device_id"],
        threshold: 100.0
      },
      %__MODULE__{
        name: "memory_usage",
        resource_type: "memory",
        metric_class: "memory",
        metric_name: "usage_percent",
        query:
          "in:memory_metrics time:#{time_range} bucket:1h stats:avg(usage_percent) as avg_usage_percent by bucket,device_id,host_id sort:bucket:asc limit:#{limit}",
        value_field: "avg_usage_percent",
        key_fields: ["device_id", "host_id"],
        label_fields: ["host_id", "device_id"],
        threshold: 100.0
      },
      %__MODULE__{
        name: "disk_usage",
        resource_type: "disk",
        metric_class: "disk",
        metric_name: "usage_percent",
        query:
          "in:disk_metrics time:#{time_range} bucket:1h stats:avg(usage_percent) as avg_usage_percent by bucket,device_id,host_id,mount_point sort:bucket:asc limit:#{limit}",
        value_field: "avg_usage_percent",
        key_fields: ["device_id", "host_id", "mount_point"],
        label_fields: ["host_id", "mount_point", "device_id"],
        threshold: 100.0
      },
      %__MODULE__{
        name: "process_cpu_usage",
        resource_type: "process",
        metric_class: "process",
        metric_name: "cpu_usage",
        query:
          "in:process_metrics time:#{time_range} bucket:1h stats:avg(cpu_usage) as avg_cpu_usage by bucket,device_id,host_id,name sort:bucket:asc limit:#{limit}",
        value_field: "avg_cpu_usage",
        key_fields: ["device_id", "host_id", "name"],
        label_fields: ["host_id", "name", "device_id"],
        threshold: 100.0
      },
      %__MODULE__{
        name: "process_memory_usage",
        resource_type: "process",
        metric_class: "process",
        metric_name: "memory_usage",
        query:
          "in:process_metrics time:#{time_range} bucket:1h stats:avg(memory_usage) as avg_memory_usage by bucket,device_id,host_id,name sort:bucket:asc limit:#{limit}",
        value_field: "avg_memory_usage",
        key_fields: ["device_id", "host_id", "name"],
        label_fields: ["host_id", "name", "device_id"],
        threshold: 100.0
      },
      %__MODULE__{
        name: "timeseries_value",
        resource_type: "timeseries",
        metric_class: "timeseries",
        metric_name: "value",
        query:
          "in:timeseries_metrics time:#{time_range} bucket:1h stats:avg(value) as avg_value by bucket,device_id,metric_type,metric_name sort:bucket:asc limit:#{limit}",
        value_field: "avg_value",
        key_fields: ["device_id", "metric_type", "metric_name"],
        label_fields: ["device_id", "metric_type", "metric_name"]
      },
      %__MODULE__{
        name: "interface_rate",
        resource_type: "interface",
        metric_class: "interface",
        metric_name: "rate_per_second",
        query:
          "in:timeseries_metric_interface_hourly time:#{time_range} sort:bucket:asc limit:#{limit}",
        value_field: "avg_rate_per_second",
        key_fields: ["device_id", "target_device_ip", "if_index", "metric_name", "series_key"],
        label_fields: ["target_device_ip", "if_index", "metric_name"]
      },
      %__MODULE__{
        name: "flow_bps",
        resource_type: "flow",
        metric_class: "flow",
        metric_name: "bps",
        query:
          "in:flows time:#{time_range} bucket:1h stats:sum(bytes_total) as bytes_total by bucket sort:bucket:asc limit:#{limit}",
        value_field: "bytes_total",
        key_fields: [],
        label_fields: []
      }
    ]
  end

  @spec from_config(map() | keyword() | t()) :: t()
  def from_config(%__MODULE__{} = source), do: source

  def from_config(config) when is_list(config) or is_map(config) do
    values = Map.new(config)

    struct!(__MODULE__, %{
      name: string_value(values, :name),
      resource_type: string_value(values, :resource_type),
      metric_class: string_value(values, :metric_class),
      metric_name: string_value(values, :metric_name),
      query: string_value(values, :query),
      value_field: string_value(values, :value_field, "value"),
      bucket_field: string_value(values, :bucket_field, "bucket"),
      key_fields: string_list(values, :key_fields),
      label_fields: string_list(values, :label_fields),
      threshold: number_value(values, :threshold),
      model: string_value(values, :model, "auto")
    })
  end

  defp string_value(values, key, default \\ nil) do
    case Map.get(values, key, Map.get(values, to_string(key), default)) do
      value when is_binary(value) -> value
      value when is_atom(value) -> Atom.to_string(value)
      nil -> nil
      value -> to_string(value)
    end
  end

  defp string_list(values, key) do
    values
    |> Map.get(key, Map.get(values, to_string(key), []))
    |> List.wrap()
    |> Enum.map(&to_string/1)
  end

  defp number_value(values, key) do
    case Map.get(values, key, Map.get(values, to_string(key))) do
      value when is_number(value) -> value * 1.0
      _ -> nil
    end
  end
end
