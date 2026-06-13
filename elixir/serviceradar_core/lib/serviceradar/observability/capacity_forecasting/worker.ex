defmodule ServiceRadar.Observability.CapacityForecasting.Worker do
  @moduledoc """
  Oban worker that refreshes long-horizon capacity forecasts from SRQL CAGGs.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [period: :infinity, states: [:available, :scheduled, :executing, :retryable]]

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Observability.AnomalyConfigRuntime
  alias ServiceRadar.Observability.CapacityForecast
  alias ServiceRadar.Observability.CapacityForecasting.InterfaceCapacity
  alias ServiceRadar.Observability.CapacityForecasting.Model
  alias ServiceRadar.Observability.CapacityForecasting.Source
  alias ServiceRadar.Observability.CapacityForecasting.VerdictEmitter
  alias ServiceRadar.Observability.SRQLRunner
  alias ServiceRadar.SweepJobs.ObanSupport

  require Logger

  @default_horizon_seconds 90 * 24 * 60 * 60
  @default_min_points 24
  @default_seasonal_period 24
  @interface_octet_metrics ~w(ifInOctets ifOutOctets ifHCInOctets ifHCOutOctets)

  @impl Oban.Worker
  def perform(%Oban.Job{} = job) do
    run(job)
  end

  @doc """
  Runs one forecasting pass.

  Tests can inject `:runner`, `:sources`, and `:upsert_fun`; production uses
  `SRQLRunner` and the `CapacityForecast.upsert` Ash action.
  """
  @spec run(Oban.Job.t(), keyword()) :: :ok | {:error, term()}
  def run(%Oban.Job{args: args} = job, opts \\ []) when is_map(args) do
    opts = merge_runtime_opts(opts)

    if Keyword.get(opts, :enabled, true) do
      forecasted_at = forecasted_at(job)

      horizon_seconds =
        positive_integer(Keyword.get(opts, :horizon_seconds), @default_horizon_seconds)

      horizon_ends_at = DateTime.add(forecasted_at, horizon_seconds, :second)

      opts =
        opts
        |> Keyword.put(:forecasted_at, forecasted_at)
        |> Keyword.put(:horizon_seconds, horizon_seconds)
        |> Keyword.put(:horizon_ends_at, horizon_ends_at)

      opts
      |> sources()
      |> Enum.reduce_while(:ok, fn source, :ok ->
        case refresh_source(source, opts) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    else
      :ok
    end
  end

  @spec enqueue_now(keyword()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue_now(opts \\ []) do
    if ObanSupport.available?() do
      args = %{
        "trigger" => "manual",
        "forecasted_at" =>
          DateTime.utc_now() |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601()
      }

      args
      |> new(opts)
      |> ObanSupport.safe_insert()
    else
      {:error, :oban_unavailable}
    end
  end

  defp refresh_source(%Source{} = source, opts) do
    runner = Keyword.get(opts, :runner, SRQLRunner)
    runner_opts = Keyword.get(opts, :runner_opts, [])

    case runner.query(source.query, runner_opts) do
      {:ok, rows} ->
        rows
        |> group_rows(source)
        |> Enum.reduce_while(:ok, fn {_resource_key, rows}, :ok ->
          case forecast_rows(source, rows, opts) do
            {:ok, attrs} ->
              attrs
              |> persist_and_emit(opts)
              |> case do
                :ok -> {:cont, :ok}
                {:error, reason} -> {:halt, {:error, reason}}
              end

            {:error, reason} ->
              {:halt, {:error, reason}}
          end
        end)

      {:error, reason} ->
        Logger.warning("Capacity forecast SRQL query failed",
          source: source.name,
          reason: inspect(reason)
        )

        {:error, reason}
    end
  end

  defp forecast_rows(%Source{} = source, rows, opts) do
    source = apply_capacity_config(source, opts)
    forecasted_at = Keyword.fetch!(opts, :forecasted_at)
    horizon_seconds = Keyword.fetch!(opts, :horizon_seconds)
    horizon_ends_at = Keyword.fetch!(opts, :horizon_ends_at)
    first_row = List.first(rows) || %{}

    common = %{
      forecasted_at: forecasted_at,
      resource_key: resource_key(source, first_row),
      resource_type: source.resource_type,
      resource_id: resource_id(source, first_row),
      resource_label: resource_label(source, first_row),
      metric_class: source.metric_class,
      metric_name: metric_name(source, first_row),
      horizon_seconds: horizon_seconds,
      horizon_ends_at: horizon_ends_at,
      exhaustion_threshold: source.threshold,
      metadata: %{
        "source" => source.name,
        "query" => source.query,
        "value_field" => source.value_field,
        "key_fields" => source.key_fields
      }
    }

    case value_context(source, first_row, opts) do
      {:ok, %{skip_reason: reason} = context} ->
        points =
          rows
          |> Enum.map(&point_from_row(&1, source, %{}))
          |> Enum.reject(&is_nil/1)

        common = Map.put(common, :metadata, Map.merge(common.metadata, context_metadata(context)))
        {:ok, skipped_attrs(source, points, common, to_string(reason))}

      {:ok, context} ->
        points =
          rows
          |> Enum.map(&point_from_row(&1, source, context))
          |> Enum.reject(&is_nil/1)

        common = Map.put(common, :metadata, Map.merge(common.metadata, context_metadata(context)))
        {:ok, forecast_attrs(source, points, common, opts)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp forecast_attrs(source, points, common, opts) do
    min_points =
      opts
      |> capacity_metric_class_override(source.metric_class)
      |> option_value("minimum_history_points", Keyword.get(opts, :min_points))
      |> positive_integer(@default_min_points)

    seasonal_period =
      positive_integer(Keyword.get(opts, :seasonal_period), @default_seasonal_period)

    case Model.forecast(points,
           min_points: min_points,
           horizon_seconds: common.horizon_seconds,
           exhaustion_threshold: common.exhaustion_threshold,
           model: source.model,
           seasonal_period: seasonal_period
         ) do
      {:ok, forecast} ->
        Map.merge(common, %{
          window_started_at: forecast.window_started_at,
          window_ended_at: forecast.window_ended_at,
          sample_count: forecast.sample_count,
          model: forecast.model,
          status: "projected",
          skip_reason: nil,
          current_value: forecast.current_value,
          slope_per_second: forecast.slope_per_second,
          intercept: forecast.intercept,
          projected_value: forecast.projected_value,
          projected_exhaustion_at: forecast.projected_exhaustion_at,
          confidence: forecast.confidence,
          lower_bound: forecast.lower_bound,
          upper_bound: forecast.upper_bound,
          metadata: Map.put(common.metadata, "diagnostics", forecast.diagnostics)
        })

      {:skip, reason, diagnostics} ->
        skipped_attrs(source, points, common, reason, diagnostics)
    end
  end

  defp skipped_attrs(source, points, common, reason, diagnostics \\ %{}) do
    Map.merge(common, %{
      window_started_at: first_point_at(points),
      window_ended_at: last_point_at(points),
      sample_count: length(points),
      model: source.model,
      status: "skipped",
      skip_reason: reason,
      current_value: nil,
      slope_per_second: nil,
      intercept: nil,
      projected_value: nil,
      projected_exhaustion_at: nil,
      confidence: nil,
      lower_bound: nil,
      upper_bound: nil,
      metadata: Map.put(common.metadata, "diagnostics", stringify_keys(diagnostics))
    })
  end

  defp upsert(attrs, opts) do
    upsert_fun = Keyword.get(opts, :upsert_fun, &upsert_forecast/2)
    actor = Keyword.get(opts, :actor, SystemActor.system(:capacity_forecasting))
    upsert_fun.(attrs, actor)
  end

  defp upsert_forecast(attrs, actor) do
    CapacityForecast
    |> Ash.Changeset.for_create(:upsert, attrs)
    |> Ash.create(actor: actor)
  end

  defp persist_and_emit(attrs, opts) do
    case upsert(attrs, opts) do
      {:ok, _forecast} -> maybe_emit_verdict(attrs, opts)
      :ok -> maybe_emit_verdict(attrs, opts)
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_upsert_result, other}}
    end
  end

  defp maybe_emit_verdict(attrs, opts) do
    if emit_verdicts?(opts) do
      emitter = Keyword.get(opts, :verdict_emitter, VerdictEmitter)
      verdict_attrs = verdict_attrs(attrs, opts)

      case emitter.emit(verdict_attrs, opts) do
        :ok ->
          :ok

        other ->
          Logger.warning("Capacity forecast verdict emit failed: #{inspect(other)}",
            resource_key: attrs[:resource_key],
            reason: inspect(other)
          )

          :ok
      end
    else
      :ok
    end
  end

  defp emit_verdicts?(opts), do: Keyword.get(opts, :emit_verdicts?, true)

  defp verdict_attrs(%{status: "projected"} = attrs, opts) do
    if at_risk?(attrs, opts), do: attrs, else: Map.put(attrs, :status, "inactive")
  end

  defp verdict_attrs(attrs, _opts), do: attrs

  defp at_risk?(
         %{
           status: "projected",
           forecasted_at: %DateTime{} = forecasted_at,
           projected_exhaustion_at: %DateTime{} = projected_exhaustion_at
         },
         opts
       ) do
    warning_horizon_seconds =
      opts
      |> Keyword.get(:warning_horizon_seconds, Keyword.fetch!(opts, :horizon_seconds))
      |> positive_integer(Keyword.fetch!(opts, :horizon_seconds))

    warning_ends_at = DateTime.add(forecasted_at, warning_horizon_seconds, :second)

    # Already-exhausted resources remain at risk; the verdict severity clamps
    # negative runway to the highest severity in VerdictEmitter.
    DateTime.compare(projected_exhaustion_at, warning_ends_at) != :gt
  end

  defp at_risk?(_attrs, _opts), do: false

  defp apply_capacity_config(%Source{} = source, opts) do
    override = capacity_metric_class_override(opts, source.metric_class)

    threshold =
      override
      |> option_value("warning_threshold_percent", Keyword.get(opts, :warning_threshold_percent))
      |> option_value_fallback(option_value(override, "threshold", source.threshold))
      |> config_number_value(source.threshold)

    model =
      override
      |> option_value("model", Keyword.get(opts, :forecast_model))
      |> option_value_fallback(source.model)

    %{source | threshold: threshold, model: to_string(model)}
  end

  defp capacity_metric_class_override(opts, metric_class) do
    opts
    |> Keyword.get(:capacity_metric_class_overrides, %{})
    |> case do
      overrides when is_map(overrides) ->
        Map.get(overrides, metric_class, Map.get(overrides, to_string(metric_class), %{}))

      _ ->
        %{}
    end
  end

  defp option_value(map, key, default) when is_map(map) do
    Map.get(map, key, Map.get(map, String.to_existing_atom(key), default))
  rescue
    ArgumentError -> Map.get(map, key, default)
  end

  defp option_value(_map, _key, default), do: default

  defp option_value_fallback(nil, fallback), do: fallback
  defp option_value_fallback("", fallback), do: fallback
  defp option_value_fallback(value, _fallback), do: value

  defp group_rows(rows, source) do
    Enum.group_by(rows, &resource_key(source, &1))
  end

  defp point_from_row(row, source, context) do
    with %DateTime{} = at <- datetime_value(row, source.bucket_field),
         value when is_number(value) <- source_value(row, source, context) do
      %{at: at, value: value}
    else
      _ -> nil
    end
  end

  defp source_value(row, %Source{resource_type: "interface"} = source, %{speed_bps: speed_bps}) do
    with value when is_number(value) <- number_value(row, source.value_field) do
      InterfaceCapacity.utilization_percent(value, speed_bps)
    end
  end

  defp source_value(row, source, _context), do: number_value(row, source.value_field)

  defp value_context(%Source{resource_type: "interface"}, row, opts) do
    resolver = Keyword.get(opts, :interface_capacity_resolver, &InterfaceCapacity.resolve/2)
    resolver_opts = Keyword.get(opts, :interface_capacity_opts, [])

    with :ok <- octet_interface_metric(row) do
      case resolver.(row, resolver_opts) do
        {:ok, %{speed_bps: speed_bps} = context} when is_integer(speed_bps) and speed_bps > 0 ->
          {:ok, context}

        {:ok, %{speed_bps: nil}} ->
          {:ok, %{skip_reason: :missing_interface_capacity}}

        {:ok, %{skip_reason: reason}} ->
          {:ok, %{skip_reason: reason}}

        {:ok, nil} ->
          {:ok, %{skip_reason: :missing_interface_capacity}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp value_context(_source, _row, _opts), do: {:ok, %{}}

  defp octet_interface_metric(row) do
    case string_value(row, "metric_name") do
      metric_name when metric_name in @interface_octet_metrics -> :ok
      _ -> {:ok, %{skip_reason: :unsupported_interface_metric}}
    end
  end

  defp context_metadata(%{speed_bps: speed_bps} = context) when is_integer(speed_bps) do
    %{
      "capacity_bps" => speed_bps,
      "capacity_source" => string_value(context, :source),
      "capacity_observed_at" => datetime_string(Map.get(context, :timestamp)),
      "forecast_value_unit" => "percent",
      "raw_value_unit" => "bytes_per_second"
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp context_metadata(%{skip_reason: reason}),
    do: %{"capacity_skip_reason" => to_string(reason)}

  defp context_metadata(_context), do: %{}

  defp sources(opts) do
    opts
    |> Keyword.get(:sources, Source.defaults())
    |> Enum.map(&Source.from_config/1)
  end

  defp forecasted_at(%Oban.Job{args: %{"forecasted_at" => iso}}) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> DateTime.truncate(dt, :microsecond)
      _ -> DateTime.truncate(DateTime.utc_now(), :microsecond)
    end
  end

  defp forecasted_at(%Oban.Job{scheduled_at: %DateTime{} = dt}),
    do: DateTime.truncate(dt, :microsecond)

  defp forecasted_at(%Oban.Job{inserted_at: %DateTime{} = dt}),
    do: DateTime.truncate(dt, :microsecond)

  defp forecasted_at(_job), do: DateTime.truncate(DateTime.utc_now(), :microsecond)

  defp resource_key(%Source{key_fields: []} = source, _row), do: source.name

  defp resource_key(%Source{} = source, row) do
    values =
      source.key_fields
      |> Enum.map(&string_value(row, &1))
      |> Enum.reject(&(&1 in [nil, ""]))

    Enum.join([source.name | values], ":")
  end

  defp resource_id(%Source{key_fields: []} = source, _row), do: source.name

  defp resource_id(%Source{} = source, row) do
    source.key_fields
    |> Enum.find_value(&string_value(row, &1))
    |> Kernel.||(resource_key(source, row))
  end

  defp resource_label(%Source{label_fields: []} = source, _row), do: source.name

  defp resource_label(%Source{} = source, row) do
    source.label_fields
    |> Enum.map(&string_value(row, &1))
    |> Enum.reject(&(&1 in [nil, ""]))
    |> case do
      [] -> resource_key(source, row)
      values -> Enum.join(values, " / ")
    end
  end

  defp metric_name(%Source{metric_name: "value"}, row) do
    string_value(row, "metric_name") || "value"
  end

  defp metric_name(%Source{metric_name: metric_name}, _row), do: metric_name

  defp datetime_value(row, field) do
    case value(row, field) do
      %DateTime{} = dt ->
        DateTime.truncate(dt, :microsecond)

      %NaiveDateTime{} = ndt ->
        ndt |> DateTime.from_naive!("Etc/UTC") |> DateTime.truncate(:microsecond)

      value when is_binary(value) ->
        parse_datetime(value)

      _ ->
        nil
    end
  end

  defp parse_datetime(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _} -> DateTime.truncate(dt, :microsecond)
      _ -> nil
    end
  end

  defp datetime_string(%DateTime{} = value), do: DateTime.to_iso8601(value)

  defp datetime_string(%NaiveDateTime{} = value),
    do: value |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_iso8601()

  defp datetime_string(_value), do: nil

  defp number_value(row, field) do
    case value(row, field) do
      value when is_number(value) -> value * 1.0
      value when is_binary(value) -> parse_float(value)
      _ -> nil
    end
  end

  defp parse_float(value) do
    case Float.parse(value) do
      {number, ""} -> number
      _ -> nil
    end
  end

  defp string_value(row, field) do
    case value(row, field) do
      nil -> nil
      value -> to_string(value)
    end
  end

  defp value(row, field) when is_map(row) do
    Map.get(row, field, Map.get(row, existing_atom(field)))
  rescue
    ArgumentError -> nil
  end

  defp existing_atom(field) when is_atom(field), do: field

  defp existing_atom(field) when is_binary(field) do
    String.to_existing_atom(field)
  rescue
    ArgumentError -> :__serviceradar_missing_field__
  end

  defp first_point_at([]), do: nil

  defp first_point_at(points),
    do:
      points
      |> Enum.sort_by(&DateTime.to_unix(&1.at, :microsecond))
      |> List.first()
      |> Map.fetch!(:at)

  defp last_point_at([]), do: nil

  defp last_point_at(points),
    do:
      points
      |> Enum.sort_by(&DateTime.to_unix(&1.at, :microsecond))
      |> List.last()
      |> Map.fetch!(:at)

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp positive_integer(value, _default) when is_integer(value) and value > 0, do: value

  defp positive_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} when number > 0 -> number
      _ -> default
    end
  end

  defp positive_integer(_value, default), do: default

  defp config_number_value(value, _default) when is_number(value), do: value * 1.0

  defp config_number_value(value, default) when is_binary(value) do
    case Float.parse(value) do
      {number, ""} -> number
      _ -> default
    end
  end

  defp config_number_value(_value, default), do: default

  defp merge_runtime_opts(opts) do
    config()
    |> Keyword.merge(AnomalyConfigRuntime.capacity_forecasting_opts())
    |> Keyword.merge(opts)
  end

  defp config do
    Application.get_env(:serviceradar_core, __MODULE__, [])
  end
end
