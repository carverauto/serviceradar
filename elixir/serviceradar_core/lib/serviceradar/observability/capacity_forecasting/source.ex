defmodule ServiceRadar.Observability.CapacityForecasting.Source do
  @moduledoc """
  Forecast source definitions for aggregate SRQL queries.
  """

  @default_time_range "last_180d"
  @default_limit 50_000
  @default_flow_threshold_bytes_per_hour 1_000_000_000_000.0
  @default_source_names MapSet.new(~w(memory_usage disk_usage))

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
          model: String.t(),
          value_unit: String.t() | nil,
          sustained_statistic: String.t() | nil
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
            model: "auto",
            value_unit: nil,
            sustained_statistic: nil

  @spec defaults(keyword()) :: [t()]
  def defaults(opts \\ []) do
    time_range = Keyword.get(opts, :time_range, @default_time_range)
    limit = Keyword.get(opts, :limit, @default_limit)
    include_sources = source_name_set(Keyword.get(opts, :include_sources, []))

    Enum.filter(all_sources(time_range, limit), fn source ->
      MapSet.member?(@default_source_names, source.name) or
        MapSet.member?(include_sources, source.name)
    end)
  end

  @doc """
  Names of the opt-in (non-default) forecast sources, in definition order.

  The single source of truth for every opt-in allowlist: the resource
  validation, the first-boot seeder filter, the worker's run-time validation,
  and the Settings UI checkbox list all derive from this.
  """
  @spec opt_in_names() :: [String.t()]
  def opt_in_names do
    @default_time_range
    |> all_sources(@default_limit)
    |> Enum.map(& &1.name)
    |> Enum.reject(&MapSet.member?(@default_source_names, &1))
  end

  defp all_sources(time_range, limit) do
    [
      %__MODULE__{
        name: "cpu_usage",
        resource_type: "cpu",
        metric_class: "cpu",
        metric_name: "usage_percent",
        query:
          ~s|in:timeseries_metrics metric_type:"sysmon.cpu" metric_name:"cpu.usage_percent" time:#{time_range} bucket:1h agg:avg series:uid sort:timestamp:desc limit:#{limit}|,
        value_field: "value",
        bucket_field: "timestamp",
        key_fields: ["series"],
        label_fields: ["series"],
        threshold: 90.0,
        value_unit: "percent",
        sustained_statistic: "daily_p95"
      },
      %__MODULE__{
        name: "memory_usage",
        resource_type: "memory",
        metric_class: "memory",
        metric_name: "usage_percent",
        query:
          ~s|in:timeseries_metrics metric_type:"sysmon.memory" metric_name:"memory.used_percent" time:#{time_range} bucket:1h agg:avg series:uid sort:timestamp:desc limit:#{limit}|,
        value_field: "value",
        bucket_field: "timestamp",
        key_fields: ["series"],
        label_fields: ["series"],
        threshold: 100.0,
        value_unit: "percent"
      },
      %__MODULE__{
        name: "disk_usage",
        resource_type: "disk",
        metric_class: "disk",
        metric_name: "usage_percent",
        # The mount-keyed rollup, not the device-level hourly aggregate: averaging
        # every mount on a host into one series hides a full data volume behind a
        # flat root filesystem. device_id leads key_fields so the resource id stays
        # the device and each mount becomes its own resource key.
        query:
          ~s|in:timeseries_metric_disk_hourly metric_type:"sysmon.disk" metric_name:"disk.used_percent" time:#{time_range} sort:bucket:desc limit:#{limit}|,
        value_field: "avg_value",
        bucket_field: "bucket",
        key_fields: ["device_id", "mount_point"],
        label_fields: ["device_id", "mount_point"],
        threshold: 100.0,
        value_unit: "percent"
      },
      %__MODULE__{
        name: "interface_rate",
        resource_type: "interface",
        metric_class: "interface",
        metric_name: "utilization_percent",
        query:
          "in:timeseries_metric_interface_hourly time:#{time_range} sort:bucket:desc limit:#{limit}",
        value_field: "avg_rate_per_second",
        key_fields: [
          "partition",
          "device_id",
          "target_device_ip",
          "if_index",
          "metric_name",
          "series_key"
        ],
        label_fields: ["target_device_ip", "if_index", "metric_name"],
        threshold: 90.0,
        value_unit: "percent",
        sustained_statistic: "daily_p95"
      },
      %__MODULE__{
        name: "flow_bytes_per_hour",
        resource_type: "flow",
        metric_class: "flow",
        metric_name: "bytes_per_hour",
        query:
          "in:flows time:#{time_range} bucket:1h stats:sum(bytes_total) as bytes_total by bucket sort:bucket:desc limit:#{limit}",
        value_field: "bytes_total",
        key_fields: [],
        label_fields: [],
        threshold: @default_flow_threshold_bytes_per_hour,
        value_unit: "bytes"
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
      model: string_value(values, :model, "auto"),
      value_unit: string_value(values, :value_unit),
      sustained_statistic: string_value(values, :sustained_statistic)
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

  defp source_name_set(:all),
    do: MapSet.new(all_sources(@default_time_range, @default_limit), & &1.name)

  defp source_name_set("all"), do: source_name_set(:all)

  defp source_name_set(values) do
    values
    |> List.wrap()
    |> MapSet.new(&to_string/1)
  end
end
