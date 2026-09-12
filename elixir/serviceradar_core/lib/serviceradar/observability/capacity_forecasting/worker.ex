defmodule ServiceRadar.Observability.CapacityForecasting.Worker do
  @moduledoc """
  Oban worker that refreshes long-horizon capacity forecasts from SRQL CAGGs.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [period: :infinity, states: :incomplete]

  import Ash.Expr

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Observability.AnomalyConfigRuntime
  alias ServiceRadar.Observability.CapacityForecast
  alias ServiceRadar.Observability.CapacityForecastConfig
  alias ServiceRadar.Observability.CapacityForecasting.InterfaceCapacity
  alias ServiceRadar.Observability.CapacityForecasting.Source
  alias ServiceRadar.Observability.CapacityForecasting.VerdictEmitter
  alias ServiceRadar.Observability.DispositionKernels
  alias ServiceRadar.Observability.PagedQuery
  alias ServiceRadar.Observability.SRQLRunner
  alias ServiceRadar.SweepJobs.ObanSupport

  require Ash.Query
  require Logger

  @default_horizon_seconds 90 * 24 * 60 * 60
  @default_min_points 24
  @default_seasonal_period 24
  @interface_octet_metrics ~w(ifInOctets ifOutOctets ifHCInOctets ifHCOutOctets)

  # SNMP octet counters wrap/reset; the hourly rollup then reports astronomically high
  # per-second "rates" for the affected bucket. Converted to utilization these become
  # physically impossible (>>100% of link capacity) and poison the trend fit. Mark any
  # converted interface utilization above this ceiling as a gap so the model never
  # stitches the pre-wrap and post-wrap segments together.
  # A 1-hour average interface utilization physically cannot exceed 100% of link capacity;
  # anything materially above that is an SNMP counter wrap/reset artifact in the rollup. Keep
  # a small margin for measurement jitter, then split the series at that sample.
  @max_interface_utilization_percent 150.0

  # Gauge-style percent sources (CPU, memory, disk) are already physical
  # percentages. Values outside the domain are contaminated input, so split the
  # series at that sample before the model sees it.
  @min_percent_sample 0.0
  @max_percent_sample 100.0
  @daily_sustained_min_points 20

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

      warning_horizon_seconds =
        opts
        |> Keyword.get(:warning_horizon_seconds, horizon_seconds)
        |> positive_integer(horizon_seconds)
        |> min(horizon_seconds)

      horizon_ends_at = DateTime.add(forecasted_at, horizon_seconds, :second)

      opts =
        opts
        |> Keyword.put(:forecasted_at, forecasted_at)
        |> Keyword.put(:horizon_seconds, horizon_seconds)
        |> Keyword.put(:warning_horizon_seconds, warning_horizon_seconds)
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

    case fetch_row_groups(runner, source, runner_opts, opts) do
      {:ok, row_groups} ->
        Enum.reduce_while(row_groups, :ok, fn {_resource_key, rows}, :ok ->
          case forecast_rows(source, rows, opts) do
            {:ok, attrs} ->
              attrs
              |> persist_and_emit(opts)
              |> case do
                :ok ->
                  emit_source_telemetry(source, attrs, length(rows), :ok)
                  {:cont, :ok}

                {:error, reason} ->
                  emit_source_error_telemetry(source, :persist, reason)
                  {:halt, {:error, reason}}
              end

            {:error, reason} ->
              emit_source_error_telemetry(source, :forecast, reason)
              {:halt, {:error, reason}}
          end
        end)

      {:error, reason} ->
        Logger.warning(
          "Capacity forecast SRQL query failed source=#{source.name} reason=#{inspect(reason)}",
          source: source.name,
          reason: inspect(reason)
        )

        emit_source_error_telemetry(source, :query, reason)
        {:error, reason}
    end
  end

  defp fetch_row_groups(runner, source, runner_opts, opts) do
    if function_exported?(runner, :query_page, 2) do
      PagedQuery.fetch(
        runner,
        source.query,
        runner_opts,
        opts,
        %{},
        fn groups, rows -> merge_row_groups(groups, rows, source) end,
        &finalize_row_groups/1,
        fn max_pages -> {:capacity_forecast_history_pages_exhausted, max_pages} end,
        fn other -> {:unexpected_capacity_forecast_page, other} end
      )
    else
      case runner.query(source.query, runner_opts) do
        {:ok, rows} when is_list(rows) -> {:ok, group_rows(rows, source)}
        other -> other
      end
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
      metadata:
        %{
          "source" => source.name,
          "query" => source.query,
          "value_field" => source.value_field,
          "forecast_value_unit" => source.value_unit,
          "key_fields" => source.key_fields,
          "sustained_statistic" => source.sustained_statistic
        }
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)
        |> Map.new()
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
    {contiguous_points, gap_count} = latest_contiguous_points(points)
    {forecast_points, sustained_metadata} = sustained_forecast_points(source, contiguous_points)

    common =
      if gap_count > 0 do
        update_in(common.metadata, &Map.put(&1, "gap_count", gap_count))
      else
        common
      end

    common =
      if map_size(sustained_metadata) > 0 do
        update_in(common.metadata, &Map.merge(&1, sustained_metadata))
      else
        common
      end

    min_points =
      opts
      |> capacity_metric_class_override(source.metric_class)
      |> option_value("minimum_history_points", Keyword.get(opts, :min_points))
      |> positive_integer(@default_min_points)

    seasonal_period =
      positive_integer(Keyword.get(opts, :seasonal_period), @default_seasonal_period)

    case compute_forecast(forecast_points,
           min_points: min_points,
           horizon_seconds: common.horizon_seconds,
           exhaustion_threshold: common.exhaustion_threshold,
           model: source.model,
           seasonal_period: seasonal_period,
           value_bounds: capacity_value_bounds(source)
         ) do
      {:ok, forecast} ->
        forecast_projection_attrs(source, forecast_points, common, forecast)

      {:skip, reason, diagnostics} ->
        skipped_attrs(source, forecast_points, common, reason, diagnostics)
    end
  end

  defp forecast_projection_attrs(source, forecast_points, common, forecast) do
    cond do
      threshold_already_crossed?(forecast, common.exhaustion_threshold) ->
        projected_attrs(source, common, forecast,
          projected_exhaustion_at: common.forecasted_at,
          diagnostics:
            forecast.diagnostics
            |> Map.put("threshold_already_crossed", true)
            |> Map.put("projected_exhaustion_source", "current_value")
        )

      # The kernel withheld the ETA only because the crossing lies beyond what
      # the observed history supports (twice its span), and the crossing is
      # inside the horizon: a different operator fact from "no crossing", so
      # record it with the crossing date. A short but clean growth trend is
      # then countable and explainable.
      exhaustion_history_capped_within_horizon?(forecast, common.horizon_ends_at) ->
        skipped_attrs(
          source,
          forecast_points,
          common,
          "exhaustion_beyond_history_cap",
          forecast.diagnostics
          |> Map.put("lower_bound", forecast.lower_bound)
          |> Map.put("upper_bound", forecast.upper_bound)
          |> Map.put(
            "raw_projected_exhaustion_at",
            iso8601_or_nil(forecast.raw_projected_exhaustion_at)
          )
          |> put_history_cap_diagnostics(forecast),
          model: forecast.model
        )

      # Capped AND beyond the horizon: the history cap is not what kept this
      # series off the runway, the horizon is. Say so, with the crossing.
      raw_crossing_after_horizon?(forecast, common.horizon_ends_at) ->
        skipped_attrs(
          source,
          forecast_points,
          common,
          "outside_forecast_horizon",
          forecast.diagnostics
          |> Map.put(
            "projected_exhaustion_at",
            iso8601_or_nil(forecast.raw_projected_exhaustion_at)
          )
          |> Map.put("horizon_ends_at", common.horizon_ends_at)
          |> put_history_cap_diagnostics(forecast),
          model: forecast.model
        )

      no_projected_exhaustion?(forecast, common.exhaustion_threshold) ->
        skipped_attrs(
          source,
          forecast_points,
          common,
          "no_projected_exhaustion",
          forecast.diagnostics
          |> Map.put("lower_bound", forecast.lower_bound)
          |> Map.put("upper_bound", forecast.upper_bound),
          model: forecast.model
        )

      projected_exhaustion_after_horizon?(forecast, common.horizon_ends_at) ->
        skipped_attrs(
          source,
          forecast_points,
          common,
          "outside_forecast_horizon",
          forecast.diagnostics
          |> Map.put("projected_exhaustion_at", forecast.projected_exhaustion_at)
          |> Map.put("horizon_ends_at", common.horizon_ends_at),
          model: forecast.model
        )

      true ->
        projected_attrs(source, common, forecast)
    end
  end

  defp projected_exhaustion_after_horizon?(
         %{projected_exhaustion_at: %DateTime{} = projected_exhaustion_at},
         %DateTime{} = horizon_ends_at
       ) do
    DateTime.after?(projected_exhaustion_at, horizon_ends_at)
  end

  defp projected_exhaustion_after_horizon?(
         %{projected_exhaustion_at: %NaiveDateTime{} = projected_exhaustion_at},
         %DateTime{} = horizon_ends_at
       ) do
    projected_exhaustion_at
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.compare(horizon_ends_at)
    |> Kernel.==(:gt)
  end

  defp projected_exhaustion_after_horizon?(_forecast, _horizon_ends_at), do: false

  defp projected_attrs(source, common, forecast, overrides \\ []) do
    diagnostics =
      overrides
      |> Keyword.get(:diagnostics, forecast.diagnostics)
      |> stringify_keys()

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
      projected_value: Keyword.get(overrides, :projected_value, forecast.projected_value),
      projected_exhaustion_at:
        Keyword.get(overrides, :projected_exhaustion_at, forecast.projected_exhaustion_at),
      confidence: forecast.confidence,
      lower_bound: Keyword.get(overrides, :lower_bound, forecast.lower_bound),
      upper_bound: Keyword.get(overrides, :upper_bound, forecast.upper_bound),
      metadata:
        common.metadata
        |> put_source_value_unit(source)
        |> Map.put("diagnostics", diagnostics)
    })
  end

  defp put_source_value_unit(metadata, %Source{value_unit: value_unit})
       when is_binary(value_unit) and value_unit != "" do
    Map.put(metadata, "forecast_value_unit", value_unit)
  end

  defp put_source_value_unit(metadata, _source), do: metadata

  # The numeric forecast compute. Orchestration stays here (paging, interface
  # bytes->percent, at_risk?, the Ash upsert, telemetry, VerdictEmitter); ONLY the
  # least-squares / Holt-Winters fit moved to the Rust `dispose_capacity` kernel on
  # the shared DeepCausality substrate (OpenSpec add-core-causal-disposition-nif,
  # task 7.4). This adapter preserves the legacy forecast contract exactly (the shape
  # the now-deleted `model.ex` `forecast/2` returned, captured bit-for-bit by the
  # `capacity_parity_fixtures.json` gate): `{:ok, forecast_map}` for a projection,
  # `{:skip, reason, diagnostics}` for the insufficient-history / guard gate — so every
  # consumer below is untouched.
  defp compute_forecast(points, opts) do
    min_points = positive_integer(Keyword.get(opts, :min_points), @default_min_points)

    horizon_seconds =
      positive_integer(Keyword.get(opts, :horizon_seconds), @default_horizon_seconds)

    seasonal_period =
      positive_integer(Keyword.get(opts, :seasonal_period), @default_seasonal_period)

    threshold = Keyword.get(opts, :exhaustion_threshold)
    model_kind = capacity_model_kind(Keyword.get(opts, :model))
    {value_min, value_max} = capacity_value_bounds(Keyword.get(opts, :value_bounds))

    config = %{
      capacity_threshold: capacity_threshold(threshold),
      horizon_seconds: horizon_seconds,
      model_kind: model_kind,
      min_history: min_points,
      period: seasonal_period,
      alpha: 0.35,
      beta: 0.05,
      gamma: 0.25,
      value_min: value_min,
      value_max: value_max
    }

    row = %{
      series_key: "capacity",
      points: Enum.map(points, &nif_point/1)
    }

    request = {:capacity, %{config: config, row: row}}

    meta = %{
      horizon_seconds: horizon_seconds,
      seasonal_period: seasonal_period,
      min_points: min_points,
      points: points
    }

    case DispositionKernels.dispose_batch(:capacity, [request]) do
      [{:capacity_ok, %{disposition: disposition}}] ->
        forecast_from_disposition(disposition, meta)

      [{:error, reason}] ->
        # An ABI/contract failure (never a detection gate) — surface as a skip so the
        # row is recorded, not silently dropped, mirroring a model skip.
        {:skip, "forecast_unavailable", %{"error" => to_string(reason)}}

      other ->
        {:skip, "forecast_unavailable", %{"error" => inspect(other)}}
    end
  end

  # `{:projected, %{...}}` -> the legacy `{:ok, forecast_map}` shape. Timestamps come
  # back from the NIF as unix microseconds (so the window start's sub-second
  # component survives `DateTime.add(first_at, round(cross_x), :second)`); rebuild the
  # DateTimes the rest of the worker expects.
  defp forecast_from_disposition({:projected, payload}, meta) do
    {:ok,
     %{
       model: payload.model,
       current_value: payload.current_value,
       slope_per_second: payload.slope_per_second,
       intercept: payload.intercept,
       projected_value: payload.projected_value,
       projected_exhaustion_at: from_unix_micros(payload.projected_exhaustion_at_unix_micros),
       raw_projected_exhaustion_at:
         from_unix_micros(Map.get(payload, :raw_projected_exhaustion_at_unix_micros)),
       exhaustion_history_capped: Map.get(payload, :exhaustion_history_capped, false) == true,
       exhaustion_extrapolation_cap_seconds:
         Map.get(payload, :exhaustion_extrapolation_cap_seconds),
       confidence: payload.confidence,
       lower_bound: payload.lower_bound,
       upper_bound: payload.upper_bound,
       sample_count: payload.sample_count,
       window_started_at: from_unix_micros!(payload.window_started_at_unix_micros),
       window_ended_at: from_unix_micros!(payload.window_ended_at_unix_micros),
       diagnostics: forecast_diagnostics(payload, meta.horizon_seconds, meta.seasonal_period)
     }}
  end

  defp forecast_from_disposition({:skipped, %{reason: reason}}, meta) do
    # The insufficient-history gate (and the kernel's finite guards) -> the legacy
    # `{:skip, reason, diagnostics}` tuple, carrying the diagnostics the legacy model
    # emitted (now the `insufficient_history` skip in `capacity.rs`).
    {:skip, to_string(reason), %{sample_count: length(meta.points), min_points: meta.min_points}}
  end

  defp forecast_from_disposition(other, _meta) do
    {:skip, "forecast_unavailable", %{"error" => inspect(other)}}
  end

  # Rebuild the legacy diagnostics map per model (the keys the deleted `model.ex`
  # emitted in its `linear` / `holt_winters_additive` diagnostics, now reproduced by
  # `capacity.rs`). The diagnostics ride in metadata only (not part of the 1e-9 numeric
  # parity gate); we reconstruct every key the worker has without re-deriving model
  # internals.
  defp forecast_diagnostics(
         %{model: "holt_winters_additive", rmse: rmse} = payload,
         horizon_seconds,
         period
       ) do
    put_projection_diagnostics(
      %{
        "rmse" => rmse,
        "horizon_seconds" => horizon_seconds,
        "period" => period,
        "model" => "holt_winters_additive"
      },
      payload
    )
  end

  defp forecast_diagnostics(%{model: model, rmse: rmse} = payload, horizon_seconds, _period) do
    put_projection_diagnostics(
      %{"rmse" => rmse, "horizon_seconds" => horizon_seconds, "model" => model},
      payload
    )
  end

  defp put_projection_diagnostics(diagnostics, payload) when is_map(payload) do
    diagnostics
    |> maybe_put_number("raw_projected_value", Map.get(payload, :raw_projected_value))
    |> maybe_put_boolean("projection_bounded", Map.get(payload, :projection_bounded))
  end

  defp maybe_put_number(map, key, value) when is_number(value), do: Map.put(map, key, value)
  defp maybe_put_number(map, _key, _value), do: map

  defp maybe_put_boolean(map, key, value) when is_boolean(value), do: Map.put(map, key, value)
  defp maybe_put_boolean(map, _key, _value), do: map

  # Map the worker's `source.model` (a string after config merge) onto the NIF
  # `CapacityModelKind` atom. Mirrors the legacy model-choice dispatch keys (now the
  # `Disposition`/`model_kind` selection in `capacity.rs`).
  defp capacity_model_kind(model)
       when model in [:seasonal, "seasonal", :holt_winters, "holt_winters"], do: :seasonal

  defp capacity_model_kind(model) when model in [:linear, "linear"], do: :linear
  defp capacity_model_kind(_model), do: :auto

  # `:exhaustion_threshold` -> the NIF's `Option<f64>` (encoded as the value or nil).
  defp capacity_threshold(threshold) when is_number(threshold), do: threshold * 1.0
  defp capacity_threshold(_threshold), do: nil

  defp capacity_value_bounds(%Source{} = source) do
    if percent_capacity_source?(source), do: {0.0, 100.0}
  end

  defp capacity_value_bounds({min, max}) when is_number(min) and is_number(max) and min < max,
    do: {min * 1.0, max * 1.0}

  defp capacity_value_bounds(_bounds), do: {nil, nil}

  defp nif_point(%{at: %DateTime{} = at, value: value}) do
    %{at_unix_micros: DateTime.to_unix(at, :microsecond), value: value * 1.0}
  end

  defp from_unix_micros(nil), do: nil
  defp from_unix_micros(micros) when is_integer(micros), do: from_unix_micros!(micros)

  defp from_unix_micros!(micros) when is_integer(micros),
    do: DateTime.from_unix!(micros, :microsecond)

  defp exhaustion_history_capped_within_horizon?(
         %{exhaustion_history_capped: true, raw_projected_exhaustion_at: %DateTime{} = raw},
         %DateTime{} = horizon_ends_at
       ),
       do: not DateTime.after?(raw, horizon_ends_at)

  defp exhaustion_history_capped_within_horizon?(_forecast, _horizon_ends_at), do: false

  defp raw_crossing_after_horizon?(
         %{
           exhaustion_history_capped: true,
           raw_projected_exhaustion_at: %DateTime{} = raw,
           projected_exhaustion_at: nil
         },
         %DateTime{} = horizon_ends_at
       ),
       do: DateTime.after?(raw, horizon_ends_at)

  defp raw_crossing_after_horizon?(_forecast, _horizon_ends_at), do: false

  defp put_history_cap_diagnostics(diagnostics, forecast) do
    diagnostics
    |> Map.put(
      "history_span_seconds",
      DateTime.diff(forecast.window_ended_at, forecast.window_started_at, :second)
    )
    |> Map.put("extrapolation_cap_seconds", forecast.exhaustion_extrapolation_cap_seconds)
  end

  defp iso8601_or_nil(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp iso8601_or_nil(_value), do: nil

  defp no_projected_exhaustion?(forecast, threshold)
       when is_number(threshold) and threshold > 0 do
    not threshold_already_crossed?(forecast, threshold) and
      (is_nil(Map.get(forecast, :projected_exhaustion_at)) or
         prediction_interval_lower_bound_misses_threshold?(forecast, threshold))
  end

  defp no_projected_exhaustion?(_forecast, _threshold), do: false

  defp prediction_interval_lower_bound_misses_threshold?(%{lower_bound: lower_bound}, threshold)
       when is_number(lower_bound) do
    lower_bound < threshold
  end

  defp prediction_interval_lower_bound_misses_threshold?(_forecast, _threshold), do: false

  defp threshold_already_crossed?(%{current_value: current_value}, threshold)
       when is_number(current_value) and is_number(threshold) do
    current_value >= threshold
  end

  defp threshold_already_crossed?(_forecast, _threshold), do: false

  defp percent_capacity_source?(%Source{value_unit: value_unit}) when is_binary(value_unit) do
    value_unit
    |> String.downcase()
    |> Kernel.in(["%", "percent", "percentage"])
  end

  defp percent_capacity_source?(%Source{metric_name: metric_name}) when is_binary(metric_name),
    do: String.ends_with?(metric_name, ["usage_percent", "utilization_percent"])

  defp percent_capacity_source?(_source), do: false

  defp skipped_attrs(source, points, common, reason, diagnostics \\ %{}, overrides \\ []) do
    Map.merge(common, %{
      window_started_at: first_point_at(points),
      window_ended_at: last_point_at(points),
      sample_count: length(points),
      model: Keyword.get(overrides, :model, source.model),
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
      verdict_attrs = verdict_attrs(attrs, opts)

      case capacity_transition_decision(attrs, verdict_attrs, opts) do
        :emit -> emit_capacity_verdict(verdict_attrs, opts)
        :skip -> :ok
      end
    else
      :ok
    end
  end

  defp emit_capacity_verdict(verdict_attrs, opts) do
    emitter = Keyword.get(opts, :verdict_emitter, VerdictEmitter)

    case emitter.emit(verdict_attrs, opts) do
      :ok ->
        :ok

      other ->
        Logger.warning("Capacity forecast verdict emit failed: #{inspect(other)}",
          resource_key: Map.get(verdict_attrs, :resource_key),
          reason: inspect(other)
        )

        :ok
    end
  end

  defp capacity_transition_decision(attrs, verdict_attrs, opts) do
    if Keyword.get(opts, :transition_only_verdicts?, true) do
      confirm_runs =
        opts
        |> Keyword.get(:capacity_transition_confirm_runs)
        |> positive_integer(2)

      history_limit =
        opts
        |> Keyword.get(:capacity_transition_history_runs)
        |> positive_integer(max(confirm_runs * 4, 6))

      current_state = capacity_verdict_state(verdict_attrs)

      case previous_forecasts(attrs, opts, history_limit) do
        {:ok, previous} ->
          previous_states = Enum.map(previous, &capacity_verdict_state(verdict_attrs(&1, opts)))
          states = [current_state | previous_states]
          current_confirmed = confirmed_state_at_head(states, confirm_runs)
          prior_confirmed = latest_confirmed_state(previous_states, confirm_runs)

          confirmed_capacity_transition_decision(current_confirmed, prior_confirmed)

        {:error, reason} ->
          Logger.warning("Capacity forecast transition lookup failed; emitting verdict",
            resource_key: Map.get(attrs, :resource_key),
            reason: inspect(reason)
          )

          :emit
      end
    else
      :emit
    end
  end

  defp confirmed_capacity_transition_decision(nil, _prior_confirmed), do: :skip
  defp confirmed_capacity_transition_decision(:projected, nil), do: :emit
  defp confirmed_capacity_transition_decision(:cleared, nil), do: :skip
  defp confirmed_capacity_transition_decision(state, state), do: :skip
  defp confirmed_capacity_transition_decision(_current_confirmed, _prior_confirmed), do: :emit

  defp confirmed_state_at_head(states, confirm_runs) do
    states
    |> Enum.take(confirm_runs)
    |> confirmed_state(confirm_runs)
  end

  defp latest_confirmed_state(states, confirm_runs) do
    cond do
      length(states) < confirm_runs ->
        nil

      state = confirmed_state_at_head(states, confirm_runs) ->
        state

      true ->
        states
        |> tl()
        |> latest_confirmed_state(confirm_runs)
    end
  end

  defp confirmed_state(states, confirm_runs) when length(states) == confirm_runs do
    first = List.first(states)

    if Enum.all?(states, &(&1 == first)), do: first
  end

  defp confirmed_state(_states, _confirm_runs), do: nil

  defp capacity_verdict_state(%{status: "projected"}), do: :projected

  defp capacity_verdict_state(%{status: status})
       when status in ["inactive", "resolved", "closed", "skipped"],
       do: :cleared

  defp capacity_verdict_state(_attrs), do: :cleared

  defp previous_forecasts(attrs, opts, limit) do
    actor = Keyword.get(opts, :actor, SystemActor.system(:capacity_forecasting))

    cond do
      loader = Keyword.get(opts, :previous_forecasts_loader) ->
        normalize_previous_forecasts(loader.(attrs, actor, limit))

      loader = Keyword.get(opts, :previous_forecast_loader) ->
        normalize_previous_forecasts(loader.(attrs, actor))

      true ->
        load_previous_forecasts(attrs, actor, limit)
    end
  end

  defp normalize_previous_forecasts({:ok, forecasts}), do: normalize_previous_forecasts(forecasts)
  defp normalize_previous_forecasts({:error, reason}), do: {:error, reason}
  defp normalize_previous_forecasts(nil), do: {:ok, []}

  defp normalize_previous_forecasts(forecasts) when is_list(forecasts) do
    if Enum.all?(forecasts, &capacity_forecast_like?/1) do
      {:ok, forecasts}
    else
      {:error, {:unexpected_previous_forecast_result, forecasts}}
    end
  end

  defp normalize_previous_forecasts(%CapacityForecast{} = forecast), do: {:ok, [forecast]}
  defp normalize_previous_forecasts(forecast) when is_map(forecast), do: {:ok, [forecast]}

  defp normalize_previous_forecasts(other),
    do: {:error, {:unexpected_previous_forecast_result, other}}

  defp capacity_forecast_like?(%CapacityForecast{}), do: true
  defp capacity_forecast_like?(forecast) when is_map(forecast), do: true
  defp capacity_forecast_like?(_forecast), do: false

  defp load_previous_forecasts(attrs, actor, limit) do
    resource_key = Map.fetch!(attrs, :resource_key)
    metric_name = Map.fetch!(attrs, :metric_name)
    horizon_seconds = Map.fetch!(attrs, :horizon_seconds)
    forecasted_at = Map.fetch!(attrs, :forecasted_at)

    CapacityForecast
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> Ash.Query.filter(
      expr(
        resource_key == ^resource_key and metric_name == ^metric_name and
          horizon_seconds == ^horizon_seconds and forecasted_at < ^forecasted_at
      )
    )
    |> Ash.Query.sort(forecasted_at: :desc)
    |> Ash.Query.limit(limit)
    |> Ash.read(actor: actor)
  end

  defp emit_source_telemetry(%Source{} = source, attrs, row_count, result) do
    :telemetry.execute(
      [:serviceradar, :observability, :capacity_forecasting, :source],
      %{
        count: 1,
        rows: non_negative(row_count),
        sample_count: non_negative(Map.get(attrs, :sample_count))
      },
      %{
        source: source.name,
        metric_class: source.metric_class,
        metric_name: source.metric_name,
        status: Map.get(attrs, :status) || "unknown",
        skip_reason: Map.get(attrs, :skip_reason) || "none",
        result: result
      }
    )

    :ok
  end

  defp emit_source_error_telemetry(%Source{} = source, phase, reason) do
    :telemetry.execute(
      [:serviceradar, :observability, :capacity_forecasting, :source],
      %{count: 1, rows: 0, sample_count: 0},
      %{
        source: source.name,
        metric_class: source.metric_class,
        metric_name: source.metric_name,
        status: "error",
        skip_reason: "none",
        phase: phase,
        result: :error,
        reason_class: reason_class(reason)
      }
    )

    :ok
  end

  defp non_negative(value) when is_integer(value) and value >= 0, do: value
  defp non_negative(value) when is_float(value) and value >= 0, do: value
  defp non_negative(_value), do: 0

  defp reason_class(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_class({reason, _}) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_class(%_{}), do: "exception"
  defp reason_class(_reason), do: "error"

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
      |> option_value("warning_threshold_percent", nil)
      |> option_value_fallback(option_value(override, "threshold", nil))
      |> option_value_fallback(percent_threshold_default(source, opts))
      |> config_number_value(source.threshold)

    model =
      override
      |> option_value("model", Keyword.get(opts, :forecast_model))
      |> option_value_fallback(source.model)

    %{source | threshold: threshold, model: to_string(model)}
  end

  defp percent_threshold_default(%Source{metric_name: "utilization_percent"}, opts),
    do: Keyword.get(opts, :warning_threshold_percent)

  defp percent_threshold_default(%Source{metric_name: "usage_percent"}, opts),
    do: Keyword.get(opts, :warning_threshold_percent)

  defp percent_threshold_default(_source, _opts), do: nil

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
    rows
    |> Enum.filter(&resource_key_present?(source, &1))
    |> Enum.group_by(&resource_key(source, &1))
  end

  defp merge_row_groups(groups, rows, source) do
    rows
    |> Enum.filter(&resource_key_present?(source, &1))
    |> Enum.reduce(groups, fn row, acc ->
      Map.update(acc, resource_key(source, row), [row], &[row | &1])
    end)
  end

  defp finalize_row_groups(groups) do
    Map.new(groups, fn {resource_key, rows} -> {resource_key, Enum.reverse(rows)} end)
  end

  defp latest_contiguous_points(points) do
    sorted_points = Enum.sort_by(points, &point_time_micros/1)
    gap_count = Enum.count(sorted_points, &Map.get(&1, :gap?, false))

    forecast_points =
      sorted_points
      |> Enum.reduce([[]], fn
        %{gap?: true}, segments -> [[] | segments]
        point, [segment | rest] -> [[point | segment] | rest]
      end)
      |> List.first([])
      |> Enum.reverse()

    {forecast_points, gap_count}
  end

  defp sustained_forecast_points(%Source{sustained_statistic: statistic}, points)
       when statistic in ["daily_p95", :daily_p95] do
    daily_points =
      points
      |> Enum.group_by(&DateTime.to_date(&1.at))
      |> Enum.map(fn {_date, day_points} -> sustained_daily_point(day_points) end)
      |> Enum.reject(&is_nil/1)
      |> Enum.sort_by(&point_time_micros/1)

    metadata = %{
      "sustained_statistic" => "daily_p95",
      "sustained_input_points" => length(points),
      "sustained_min_points_per_day" => @daily_sustained_min_points
    }

    {daily_points, metadata}
  end

  defp sustained_forecast_points(_source, points), do: {points, %{}}

  defp sustained_daily_point(day_points) do
    value_points =
      day_points
      |> Enum.filter(&(is_number(Map.get(&1, :value)) and match?(%DateTime{}, Map.get(&1, :at))))
      |> Enum.sort_by(&point_time_micros/1)

    if length(value_points) >= @daily_sustained_min_points do
      %{
        at: value_points |> List.last() |> Map.fetch!(:at),
        value: percentile_cont(Enum.map(value_points, & &1.value), 0.95)
      }
    end
  end

  defp percentile_cont(values, percentile) when is_list(values) do
    values = Enum.sort(values)
    count = length(values)

    cond do
      count == 0 ->
        nil

      count == 1 ->
        List.first(values) * 1.0

      true ->
        rank = percentile * (count - 1)
        lower_index = rank |> :math.floor() |> trunc()
        upper_index = rank |> :math.ceil() |> trunc()
        lower = Enum.at(values, lower_index)
        upper = Enum.at(values, upper_index)
        lower + (upper - lower) * (rank - lower_index)
    end
  end

  defp point_from_row(row, source, context) do
    case datetime_value(row, source.bucket_field) do
      %DateTime{} = at ->
        case source_value(row, source, context) do
          value when is_number(value) -> %{at: at, value: value}
          {:gap, reason} -> %{at: at, gap?: true, reason: reason}
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp source_value(row, %Source{resource_type: "interface"} = source, %{speed_bps: speed_bps}) do
    case number_value(row, source.value_field) do
      value when is_number(value) ->
        utilization = InterfaceCapacity.utilization_percent(value, speed_bps)

        if utilization > @max_interface_utilization_percent do
          {:gap, :counter_wrap}
        else
          utilization
        end

      _ ->
        nil
    end
  end

  defp source_value(row, %Source{resource_type: resource_type} = source, _context) do
    case number_value(row, source.value_field) do
      value when is_number(value) ->
        if resource_type != "interface" and percent_capacity_source?(source) and
             (value < @min_percent_sample or value > @max_percent_sample) do
          {:gap, :out_of_domain_percent}
        else
          value
        end

      _ ->
        nil
    end
  end

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
    |> Keyword.get(
      :sources,
      Source.defaults(include_sources: validated_source_opt_ins(opts))
    )
    |> Enum.map(&Source.from_config/1)
  end

  defp validated_source_opt_ins(opts) do
    opt_ins =
      opts
      |> Keyword.get(:default_source_opt_ins, [])
      |> List.wrap()
      |> Enum.map(&to_string/1)

    known = Source.opt_in_names()
    {valid, unknown} = Enum.split_with(opt_ins, &(&1 in known))

    if unknown != [] do
      Logger.warning(
        "Ignoring unknown capacity forecasting source opt-ins: #{Enum.join(unknown, ", ")}",
        known_sources: known
      )
    end

    valid
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

  defp resource_key_present?(%Source{key_fields: []}, _row), do: true

  defp resource_key_present?(%Source{} = source, row) do
    Enum.any?(source.key_fields, &present_string_value(row, &1))
  end

  defp resource_id(%Source{key_fields: []} = source, _row), do: source.name

  defp resource_id(%Source{resource_type: "interface"} = source, row) do
    device =
      Enum.find_value(
        [
          "device_id",
          "target_device_id",
          "device_uid",
          "source_device_uid",
          "target_device_ip",
          "host",
          "agent_id"
        ],
        &present_string_value(row, &1)
      )

    if_index = present_string_value(row, "if_index")

    cond do
      device && if_index -> "#{device}:if#{if_index}"
      device -> device
      true -> resource_key(source, row)
    end
  end

  defp resource_id(%Source{} = source, row) do
    source.key_fields
    |> Enum.find_value(&present_string_value(row, &1))
    |> Kernel.||(resource_key(source, row))
  end

  # A key field that is present but blank (e.g. the sysmon series uid resolves to "")
  # must NOT be treated as the resource_id: an empty string is truthy in Elixir, so a raw
  # find_value would return "" and short-circuit the resource_key fallback, producing a
  # blank resource_id that fails the required-attribute check and halts the whole worker
  # run (blocking every later source's forecasts too).
  defp present_string_value(row, field) do
    case string_value(row, field) do
      value when value in [nil, ""] -> nil
      value -> value
    end
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

  defp point_time_micros(%{at: %DateTime{} = at}), do: DateTime.to_unix(at, :microsecond)

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
    base_config = config()

    base_config
    |> Keyword.merge(runtime_capacity_forecasting_opts(base_config, opts))
    |> Keyword.merge(opts)
  end

  defp config do
    Application.get_env(:serviceradar_core, __MODULE__, [])
  end

  defp runtime_capacity_forecasting_opts(base_config, opts) do
    control_opts = Keyword.merge(base_config, opts)

    case Keyword.get(control_opts, :runtime_config_source, :database) do
      source when source in [:cache, "cache"] ->
        AnomalyConfigRuntime.capacity_forecasting_opts()

      source when source in [:none, "none", false] ->
        []

      _source ->
        case fetch_capacity_forecasting_opts(control_opts) do
          {:ok, runtime_opts} ->
            runtime_opts

          {:error, reason} ->
            Logger.warning("Capacity forecasting config fetch failed; using cached runtime opts",
              reason: inspect(reason)
            )

            AnomalyConfigRuntime.capacity_forecasting_opts()
        end
    end
  end

  defp fetch_capacity_forecasting_opts(opts) do
    actor = Keyword.get(opts, :actor, SystemActor.system(:capacity_forecasting_config))
    fetcher = Keyword.get(opts, :runtime_opts_fetcher, &fetch_capacity_forecast_settings/1)

    case fetcher.(actor) do
      {:ok, %CapacityForecastConfig{} = settings} ->
        {:ok, AnomalyConfigRuntime.capacity_forecasting_opts_from_settings(settings)}

      {:ok, runtime_opts} when is_list(runtime_opts) ->
        {:ok, runtime_opts}

      {:ok, nil} ->
        {:ok, []}

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:unexpected_capacity_forecast_config_result, other}}
    end
  end

  defp fetch_capacity_forecast_settings(actor) do
    [CapacityForecastConfig]
    |> Ash.transaction(fn ->
      CapacityForecastConfig.get_settings(actor: actor)
    end)
    |> case do
      {:ok, {:ok, settings}} -> {:ok, settings}
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
      {:error, reason, _stacktrace} -> {:error, reason}
    end
  end
end
