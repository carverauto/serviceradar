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
  alias ServiceRadar.Observability.CapacityForecasting.Source
  alias ServiceRadar.Observability.CapacityForecasting.VerdictEmitter
  alias ServiceRadar.Observability.CausalReasoner
  alias ServiceRadar.Observability.SRQLRunner
  alias ServiceRadar.SweepJobs.ObanSupport

  require Logger

  @default_horizon_seconds 90 * 24 * 60 * 60
  @default_min_points 24
  @default_seasonal_period 24
  @interface_octet_metrics ~w(ifInOctets ifOutOctets ifHCInOctets ifHCOutOctets)

  # SNMP octet counters wrap/reset; the hourly rollup then reports astronomically high
  # per-second "rates" for the affected bucket. Converted to utilization these become
  # physically impossible (>>100% of link capacity) and poison the trend fit. Drop any
  # converted interface utilization above this ceiling as a counter artifact.
  # A 1-hour average interface utilization physically cannot exceed 100% of link capacity;
  # anything materially above that is an SNMP counter wrap/reset artifact in the rollup. Keep
  # a small margin for measurement jitter, then drop the sample so it can't poison the trend.
  @max_interface_utilization_percent 150.0

  # Safety net: even after dropping contaminated samples, refuse to persist an absurd
  # projection for a bounded-threshold metric (e.g. utilization_percent). A projected
  # value beyond this multiple of the threshold is recorded as a skip, not rendered.
  @implausible_projection_factor 10.0

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

    case fetch_rows(runner, source.query, runner_opts, opts) do
      {:ok, rows} ->
        rows
        |> group_rows(source)
        |> Enum.reduce_while(:ok, fn {_resource_key, rows}, :ok ->
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
        Logger.warning("Capacity forecast SRQL query failed",
          source: source.name,
          reason: inspect(reason)
        )

        emit_source_error_telemetry(source, :query, reason)
        {:error, reason}
    end
  end

  defp fetch_rows(runner, query, runner_opts, opts) do
    if function_exported?(runner, :query_page, 2) do
      max_pages = positive_integer(Keyword.get(opts, :max_history_pages), 100)
      fetch_rows_page(runner, query, runner_opts, nil, [], 0, max_pages)
    else
      runner.query(query, runner_opts)
    end
  end

  defp fetch_rows_page(_runner, _query, _runner_opts, _cursor, _pages, page_count, max_pages)
       when page_count >= max_pages,
       do: {:error, {:capacity_forecast_history_pages_exhausted, max_pages}}

  defp fetch_rows_page(runner, query, runner_opts, cursor, pages, page_count, max_pages) do
    page_opts =
      if is_binary(cursor), do: Keyword.put(runner_opts, :cursor, cursor), else: runner_opts

    case runner.query_page(query, page_opts) do
      {:ok, %{rows: rows, next_cursor: next_cursor}} when is_list(rows) ->
        pages = [rows | pages]

        if is_binary(next_cursor) and next_cursor != "" do
          fetch_rows_page(
            runner,
            query,
            runner_opts,
            next_cursor,
            pages,
            page_count + 1,
            max_pages
          )
        else
          {:ok, pages |> Enum.reverse() |> List.flatten()}
        end

      {:ok, %{rows: rows}} when is_list(rows) ->
        {:ok, [rows | pages] |> Enum.reverse() |> List.flatten()}

      {:ok, other} ->
        {:error, {:unexpected_capacity_forecast_page, other}}

      {:error, reason} ->
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

    case compute_forecast(points,
           min_points: min_points,
           horizon_seconds: common.horizon_seconds,
           exhaustion_threshold: common.exhaustion_threshold,
           model: source.model,
           seasonal_period: seasonal_period
         ) do
      {:ok, forecast} ->
        if implausible_projection?(forecast, common.exhaustion_threshold) do
          skipped_attrs(source, points, common, "implausible_projection", forecast.diagnostics)
        else
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
        end

      {:skip, reason, diagnostics} ->
        skipped_attrs(source, points, common, reason, diagnostics)
    end
  end

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

    config = %{
      capacity_threshold: capacity_threshold(threshold),
      horizon_seconds: horizon_seconds,
      model_kind: model_kind,
      min_history: min_points,
      period: seasonal_period,
      alpha: 0.35,
      beta: 0.05,
      gamma: 0.25
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

    case CausalReasoner.dispose_batch(:capacity, [request]) do
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
         %{model: "holt_winters_additive", rmse: rmse},
         horizon_seconds,
         period
       ) do
    %{
      "rmse" => rmse,
      "horizon_seconds" => horizon_seconds,
      "period" => period,
      "model" => "holt_winters_additive"
    }
  end

  defp forecast_diagnostics(%{model: model, rmse: rmse}, horizon_seconds, _period) do
    %{"rmse" => rmse, "horizon_seconds" => horizon_seconds, "model" => model}
  end

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

  defp nif_point(%{at: %DateTime{} = at, value: value}) do
    %{at_unix_micros: DateTime.to_unix(at, :microsecond), value: value * 1.0}
  end

  defp from_unix_micros(nil), do: nil
  defp from_unix_micros(micros) when is_integer(micros), do: from_unix_micros!(micros)

  defp from_unix_micros!(micros) when is_integer(micros),
    do: DateTime.from_unix!(micros, :microsecond)

  # A bounded-threshold metric (e.g. utilization_percent) that projects far beyond its
  # threshold is contaminated input, not a real forecast — skip it rather than render an
  # impossible value. Unbounded metrics (no threshold) are never clamped.
  defp implausible_projection?(%{projected_value: projected_value}, threshold)
       when is_number(projected_value) and is_number(threshold) and threshold > 0 do
    projected_value > @implausible_projection_factor * threshold
  end

  defp implausible_projection?(_forecast, _threshold), do: false

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
    case number_value(row, source.value_field) do
      value when is_number(value) ->
        utilization = InterfaceCapacity.utilization_percent(value, speed_bps)

        # Drop counter-wrap/reset artifacts so they never reach the model.
        if utilization > @max_interface_utilization_percent, do: nil, else: utilization

      _ ->
        nil
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
