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
  @default_profile_timezone "Etc/UTC"
  @interface_rate_metrics ~w(ifInOctets ifOutOctets ifInUcastPkts ifOutUcastPkts)
  @profile_timezone_keys [
    :profile_timezone,
    "profile_timezone",
    :seasonal_profile_timezone,
    "seasonal_profile_timezone"
  ]
  @timezone_pattern ~r/^[A-Za-z0-9_+\-]+(?:\/[A-Za-z0-9_+\-]+)*$/
  @zoneinfo_dirs ["/usr/share/zoneinfo", "/usr/share/lib/zoneinfo"]

  # `:p05p95` (no underscore) is the exact NIF `RobustStatistic` ABI atom; see
  # `robust_statistic_value/2` for why the underscore form is normalized away.
  @type robust_statistic :: :mean_stddev | :median_mad | :p05p95

  @type t :: %__MODULE__{
          name: String.t(),
          resource_type: String.t(),
          metric_class: String.t(),
          metric_name: String.t(),
          wire_metric_name: String.t(),
          query: String.t(),
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
          profile_timezone: String.t(),
          label_fields: [String.t()]
        }

  defstruct name: nil,
            resource_type: nil,
            metric_class: nil,
            metric_name: nil,
            wire_metric_name: nil,
            query: nil,
            # Default to the robust median/MAD statistic (1.15) so a past incident hour
            # cannot poison the seasonal baseline (the profile verb supplies center/mad).
            robust_statistic: :median_mad,
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
            profile_timezone: @default_profile_timezone,
            label_fields: []

  @spec defaults(keyword()) :: [t()]
  def defaults(opts \\ []) do
    time_range = Keyword.get(opts, :time_range, @default_time_range)
    limit = Keyword.get(opts, :limit, @default_limit)
    profile_timezone = profile_timezone_value(opts)

    host_sources = [
      %__MODULE__{
        name: "cpu_seasonal",
        resource_type: "cpu",
        metric_class: "cpu",
        metric_name: "usage_percent",
        wire_metric_name: "cpu.usage_percent",
        query:
          profile_query("sysmon.cpu", "cpu.usage_percent", time_range, limit, profile_timezone),
        robust_statistic: :median_mad,
        profile_timezone: profile_timezone,
        label_fields: ["series"]
      },
      %__MODULE__{
        name: "memory_seasonal",
        resource_type: "memory",
        metric_class: "memory",
        metric_name: "usage_percent",
        wire_metric_name: "memory.used_percent",
        query:
          profile_query(
            "sysmon.memory",
            "memory.used_percent",
            time_range,
            limit,
            profile_timezone
          ),
        robust_statistic: :median_mad,
        profile_timezone: profile_timezone,
        label_fields: ["series"]
      }
    ]

    host_sources ++ interface_sources(time_range, limit, profile_timezone)
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
      wire_metric_name: wire_metric_name_value(values),
      query: string_value(values, :query),
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
      profile_timezone: profile_timezone_value(values),
      label_fields: string_list(values, :label_fields)
    })
  end

  # The full dotted metric name as it appears in the timeseries series and on the wire
  # (e.g. "memory.used_percent", which deliberately diverges from
  # "<metric_class>.<metric_name>"). The add-on keys its seasonal lookup by this exact
  # string, so it is carried as a first-class field rather than re-parsed from the query.
  # A custom config whose series name diverges must set `:wire_metric_name`; otherwise we
  # derive the common `<metric_class>.<metric_name>` form.
  defp wire_metric_name_value(values) do
    case string_value(values, :wire_metric_name) do
      nil ->
        class = string_value(values, :metric_class)
        name = string_value(values, :metric_name)
        if class in [nil, ""], do: name, else: "#{class}.#{name}"

      wire ->
        wire
    end
  end

  defp profile_query(metric_type, metric_name, time_range, limit, profile_timezone) do
    ~s|in:timeseries_metrics metric_type:"#{metric_type}" metric_name:"#{metric_name}" time:#{time_range} bucket:1h agg:avg series:uid stats:profile_hour_of_week(value) timezone:"#{profile_timezone}" sort:dow:asc,hod:asc limit:#{limit}|
  end

  defp interface_sources(time_range, limit, profile_timezone) do
    Enum.map(@interface_rate_metrics, fn metric_name ->
      %__MODULE__{
        name: "interface_#{Macro.underscore(metric_name)}_seasonal",
        resource_type: "interface",
        metric_class: "interface",
        metric_name: metric_name,
        wire_metric_name: metric_name,
        query: interface_profile_query(metric_name, time_range, limit, profile_timezone),
        robust_statistic: :median_mad,
        profile_timezone: profile_timezone,
        label_fields: ["series", "if_index", "metric_name"]
      }
    end)
  end

  defp interface_profile_query(metric_name, time_range, limit, profile_timezone) do
    ~s|in:timeseries_metric_interface_hourly metric_name:"#{metric_name}" time:#{time_range} stats:profile_hour_of_week(value) timezone:"#{profile_timezone}" sort:series:asc,if_index:asc,dow:asc,hod:asc limit:#{limit}|
  end

  @doc """
  Whether the source scores against a robust statistic whose order statistics must
  already exclude the latest bucket in SQL (design D6: order stats cannot be
  de-aggregated by one point inside the kernel).
  """
  @spec robust?(t()) :: boolean()
  def robust?(%__MODULE__{robust_statistic: :mean_stddev}), do: false
  def robust?(%__MODULE__{}), do: true

  @doc """
  Whether a source belongs in central seasonal disposition.

  Seasonal disposition is intentionally limited to sustained host utilization
  signals. Disk usage is capacity-forecasting territory, and SNMP/interface or
  counter-like series stay edge-governed until they have metric-class-specific
  disposition semantics.
  """
  @spec seasonal_disposition_supported?(t()) :: boolean()
  def seasonal_disposition_supported?(%__MODULE__{
        metric_class: metric_class,
        metric_name: metric_name
      }) do
    metric_class in ["cpu", "memory"] and
      metric_name in ["usage_percent", "used_percent"]
  end

  @doc """
  Whether a source can be delivered as an edge seasonal baseline.

  This is intentionally broader than central seasonal disposition: interface
  rates are delivered to the edge for deseasonalized drift, but they do not emit
  central seasonal verdicts.
  """
  @spec baseline_delivery_supported?(t()) :: boolean()
  def baseline_delivery_supported?(%__MODULE__{} = source) do
    seasonal_disposition_supported?(source) or
      (source.resource_type == "interface" and source.metric_name in @interface_rate_metrics)
  end

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
      # Robust median/MAD is the default for missing/unknown values (1.15).
      _ -> :median_mad
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

  defp profile_timezone_value(values) when is_list(values) do
    values
    |> Map.new()
    |> profile_timezone_value()
  end

  defp profile_timezone_value(values) when is_map(values) do
    values
    |> profile_timezone_candidate()
    |> normalize_profile_timezone()
  end

  defp profile_timezone_candidate(values) do
    Enum.find_value(@profile_timezone_keys, fn key -> Map.get(values, key) end) ||
      @default_profile_timezone
  end

  defp normalize_profile_timezone(value) when value in [nil, ""], do: @default_profile_timezone
  defp normalize_profile_timezone("UTC"), do: @default_profile_timezone

  defp normalize_profile_timezone(value) do
    value = to_string(value)

    if Regex.match?(@timezone_pattern, value) and valid_profile_timezone?(value) do
      value
    else
      @default_profile_timezone
    end
  end

  defp valid_profile_timezone?(@default_profile_timezone), do: true

  defp valid_profile_timezone?(value) do
    calendar_timezone?(value) or zoneinfo_timezone?(value)
  end

  defp calendar_timezone?(value) do
    case DateTime.shift_zone(DateTime.utc_now(), value) do
      {:ok, _datetime} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  defp zoneinfo_timezone?(value) do
    Enum.any?(@zoneinfo_dirs, fn dir ->
      dir
      |> Path.join(value)
      |> File.regular?()
    end)
  end
end
