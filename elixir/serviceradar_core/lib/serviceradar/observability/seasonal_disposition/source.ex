defmodule ServiceRadar.Observability.SeasonalDisposition.Source do
  @moduledoc """
  Seasonal disposition source definitions for the 168-bucket hour-of-week profile.

  Each source pairs a profile SRQL query — the historical hour-of-week aggregation
  over the hourly CAGGs (`GROUP BY series, extract(dow), extract(hour)`) joined to
  the latest complete bucket under test — with the field names the worker reads to
  build one `SeasonalRow` per `(series, dow, hod)` profile row.

  The 168-bucket aggregation STAYS in SQL (data gravity, design D6): the SRQL layer
  emits the per-bucket summary statistics (`bucket_count`/`bucket_sum`/`bucket_sum_sq`
  for the mean/stddev statistic, and the per-bucket order statistics `center`/`mad`/
  `p05`/`p95` for the robust statistics) so the NIF moves only the residual-z, breach,
  baseline-sufficiency gate, and robust-statistic selection — never raw points.

  Mirrors `ServiceRadar.Observability.CapacityForecasting.Source`.
  """

  @default_time_range "last_180d"
  @default_limit 50_000

  # `:p05p95` (no underscore) is the exact NIF `RobustStatistic` ABI atom; see
  # `robust_statistic_value/2` for why the underscore form is normalized away.
  @type robust_statistic :: :mean_stddev | :median_mad | :p05p95

  @type t :: %__MODULE__{
          name: String.t(),
          resource_type: String.t(),
          metric_class: String.t(),
          metric_name: String.t(),
          query: String.t(),
          time_zone: String.t(),
          robust_statistic: robust_statistic(),
          series_field: String.t(),
          dow_field: String.t(),
          hod_field: String.t(),
          sample_field: String.t(),
          bucket_field: String.t(),
          count_field: String.t(),
          sum_field: String.t(),
          sum_sq_field: String.t(),
          center_field: String.t(),
          mad_field: String.t(),
          p05_field: String.t(),
          p95_field: String.t(),
          label_fields: [String.t()]
        }

  defstruct name: nil,
            resource_type: nil,
            metric_class: nil,
            metric_name: nil,
            query: nil,
            time_zone: "UTC",
            robust_statistic: :mean_stddev,
            series_field: "series",
            dow_field: "dow",
            hod_field: "hod",
            sample_field: "sample_value",
            bucket_field: "bucket",
            count_field: "bucket_count",
            sum_field: "bucket_sum",
            sum_sq_field: "bucket_sum_sq",
            center_field: "center",
            mad_field: "mad",
            p05_field: "p05",
            p95_field: "p95",
            label_fields: []

  @spec defaults(keyword()) :: [t()]
  def defaults(opts \\ []) do
    time_range = Keyword.get(opts, :time_range, @default_time_range)
    limit = Keyword.get(opts, :limit, @default_limit)
    time_zone = opts |> Keyword.get(:time_zone, "UTC") |> normalize_time_zone()

    [
      %__MODULE__{
        name: "cpu_seasonal",
        resource_type: "cpu",
        metric_class: "cpu",
        metric_name: "usage_percent",
        time_zone: time_zone,
        query:
          ~s|in:timeseries_metrics metric_type:"sysmon.cpu" metric_name:"cpu.usage_percent" timezone:"#{time_zone}" time:#{time_range} bucket:1h agg:avg series:uid stats:profile_hour_of_week(value) sort:dow:asc,hod:asc limit:#{limit}|,
        robust_statistic: :mean_stddev,
        label_fields: ["series"]
      },
      %__MODULE__{
        name: "memory_seasonal",
        resource_type: "memory",
        metric_class: "memory",
        metric_name: "usage_percent",
        time_zone: time_zone,
        query:
          ~s|in:timeseries_metrics metric_type:"sysmon.memory" metric_name:"memory.used_percent" timezone:"#{time_zone}" time:#{time_range} bucket:1h agg:avg series:uid stats:profile_hour_of_week(value) sort:dow:asc,hod:asc limit:#{limit}|,
        robust_statistic: :mean_stddev,
        label_fields: ["series"]
      },
      %__MODULE__{
        name: "disk_seasonal",
        resource_type: "disk",
        metric_class: "disk",
        metric_name: "usage_percent",
        time_zone: time_zone,
        query:
          ~s|in:timeseries_metrics metric_type:"sysmon.disk" metric_name:"disk.used_percent" timezone:"#{time_zone}" time:#{time_range} bucket:1h agg:avg series:uid stats:profile_hour_of_week(value) sort:dow:asc,hod:asc limit:#{limit}|,
        robust_statistic: :mean_stddev,
        label_fields: ["series"]
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
      time_zone: values |> string_value(:time_zone, "UTC") |> normalize_time_zone(),
      robust_statistic: robust_statistic_value(values, :robust_statistic),
      series_field: string_value(values, :series_field, "series"),
      dow_field: string_value(values, :dow_field, "dow"),
      hod_field: string_value(values, :hod_field, "hod"),
      sample_field: string_value(values, :sample_field, "sample_value"),
      bucket_field: string_value(values, :bucket_field, "bucket"),
      count_field: string_value(values, :count_field, "bucket_count"),
      sum_field: string_value(values, :sum_field, "bucket_sum"),
      sum_sq_field: string_value(values, :sum_sq_field, "bucket_sum_sq"),
      center_field: string_value(values, :center_field, "center"),
      mad_field: string_value(values, :mad_field, "mad"),
      p05_field: string_value(values, :p05_field, "p05"),
      p95_field: string_value(values, :p95_field, "p95"),
      label_fields: string_list(values, :label_fields)
    })
  end

  @doc """
  Whether the source scores against a robust statistic whose order statistics must
  already exclude the latest bucket in SQL (design D6: order stats cannot be
  de-aggregated by one point inside the kernel).
  """
  @spec robust?(t()) :: boolean()
  def robust?(%__MODULE__{robust_statistic: :mean_stddev}), do: false
  def robust?(%__MODULE__{}), do: true

  # The robust statistic atom is the NIF `RobustStatistic` `NifUnitEnum` ABI contract:
  # rustler derives the variant atom via `to_snake_case` of the Rust ident, so `P05P95`
  # decodes ONLY as `:p05p95` (NOT `:p05_p95` — there is no underscore between the
  # digit-adjacent segments). Passing `:p05_p95` to the NIF raises a decode error that
  # crashes the WHOLE `dispose_batch` call (not a per-row `{:error, _}`). We accept the
  # human-friendly `p05_p95` spelling on input for operator config back-compat, but
  # normalize to the exact ABI atom `:p05p95` that the NIF accepts.
  defp robust_statistic_value(values, key) do
    case Map.get(values, key, Map.get(values, to_string(key))) do
      :mean_stddev -> :mean_stddev
      :median_mad -> :median_mad
      :p05p95 -> :p05p95
      :p05_p95 -> :p05p95
      "mean_stddev" -> :mean_stddev
      "median_mad" -> :median_mad
      "p05p95" -> :p05p95
      "p05_p95" -> :p05p95
      _ -> :mean_stddev
    end
  end

  defp string_value(values, key, default \\ nil) do
    case Map.get(values, key, Map.get(values, to_string(key), default)) do
      value when is_binary(value) -> value
      value when is_atom(value) and not is_nil(value) -> Atom.to_string(value)
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

  defp normalize_time_zone(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> "UTC"
      "Etc/UTC" -> "UTC"
      time_zone -> time_zone
    end
  end

  defp normalize_time_zone(_value), do: "UTC"
end
