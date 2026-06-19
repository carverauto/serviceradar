defmodule ServiceRadar.Observability.SeasonalDisposition.Worker do
  @moduledoc """
  Oban worker that disposes central-seasonal anomalies from the hour-of-week profile.

  The operator directive moves seasonal residual-z / baseline-sufficiency / robust-
  statistic compute out of the BEAM and into Rust on the shared DeepCausality
  substrate (`serviceradar-anomaly-core`). This worker is the orchestration half:
  Elixir owns I/O, the NIF owns the statistics.

  Per cycle, for each `Source`:

    1. Page the 168-bucket hour-of-week profile rows from the hourly CAGGs via
       `SRQLRunner` (the `GROUP BY series, extract(dow), extract(hour)` aggregation
       STAYS in SQL — data gravity, design D6).
    2. Hydrate each profile row into the typed `{:seasonal, %{config, row}}` request
       ABI, carrying in `consecutive_anomalous` from the state store for confirm-slot
       hysteresis.
    3. Call `CausalReasoner.dispose_batch(:seasonal, rows)` once per source — the NIF
       moves only residual-z, breach, baseline-sufficiency, and robust-statistic
       selection; every gate is a typed `Disposition` value, never an unwind.
    4. Persist the returned `next_consecutive_anomalous` per `(series_key, dow, hod)`
       and emit `verdict_source: central-seasonal` verdicts for confirmed breaches
       and confirmed-breach clears via the existing `VerdictEmitter` onto the signal path.

  Mirrors `ServiceRadar.Observability.CapacityForecasting.Worker`. Tests can inject
  `:runner`, `:sources`, `:reasoner`, `:state_loader`, `:state_persister`, and
  `:verdict_emitter`; production uses `SRQLRunner`, the `CausalReasoner` NIF facade,
  and the in-memory carried state defaults.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [period: :infinity, states: [:available, :scheduled, :executing, :retryable]]

  alias ServiceRadar.Observability.AnomalyConfigRuntime
  alias ServiceRadar.Observability.CausalReasoner
  alias ServiceRadar.Observability.SeasonalDisposition.Source
  alias ServiceRadar.Observability.SeasonalDisposition.VerdictEmitter
  alias ServiceRadar.Observability.SRQLRunner
  alias ServiceRadar.SweepJobs.ObanSupport

  require Logger

  @default_n_sigma 3.0
  @default_min_bucket_samples 4
  @default_confirm_slots 1

  @impl Oban.Worker
  def perform(%Oban.Job{} = job) do
    run(job)
  end

  @doc """
  Runs one seasonal disposition pass.
  """
  @spec run(Oban.Job.t(), keyword()) :: :ok | {:error, term()}
  def run(%Oban.Job{args: args} = job, opts \\ []) when is_map(args) do
    opts = merge_runtime_opts(opts)

    if Keyword.get(opts, :enabled, true) do
      evaluated_at = evaluated_at(job)
      opts = Keyword.put(opts, :evaluated_at, evaluated_at)

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
        "evaluated_at" =>
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
        dispose_source(source, rows, opts)

      {:error, reason} ->
        Logger.warning("Seasonal disposition SRQL query failed",
          source: source.name,
          reason: inspect(reason)
        )

        emit_source_error_telemetry(source, :query, reason)
        {:error, reason}
    end
  end

  defp dispose_source(%Source{} = source, raw_rows, opts) do
    config = seasonal_config(source, opts)

    rows =
      raw_rows
      |> Enum.map(&seasonal_row(&1, source, config))
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&%{&1 | consecutive_anomalous: load_consecutive(source, &1, opts)})

    case rows do
      [] ->
        emit_source_telemetry(source, [], 0, :ok)
        :ok

      rows ->
        inputs = Enum.map(rows, &{:seasonal, %{config: config, row: row_struct(&1)}})

        case dispose_batch(inputs, opts) do
          {:ok, results, nif_us} ->
            handle_results(source, rows, results, config, nif_us, opts)

          {:error, reason} ->
            emit_source_error_telemetry(source, :nif, reason)
            {:error, reason}
        end
    end
  end

  defp handle_results(%Source{} = source, rows, results, config, nif_us, opts) do
    pairs = Enum.zip(rows, results)

    pairs
    |> Enum.reduce_while({:ok, %{}}, fn {row, result}, {:ok, acc} ->
      case process_result(source, row, result, config, opts) do
        :ok -> {:cont, {:ok, bump(acc, classify(result))}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, counts} ->
        emit_source_telemetry(source, counts, length(rows), :ok, nif_us)
        :ok

      {:error, reason} ->
        emit_source_error_telemetry(source, :persist, reason)
        {:error, reason}
    end
  end

  defp process_result(_source, _row, {:error, reason}, _config, _opts) do
    Logger.warning("Seasonal disposition row errored", reason: inspect(reason))
    :ok
  end

  defp process_result(source, row, {:ok, disposition}, config, opts) do
    next = Map.get(disposition, :next_consecutive_anomalous, 0)
    score = Map.get(disposition, :score, 0.0)
    verdict = Map.get(disposition, :disposition)

    case persist_state(source, row, next, opts) do
      :ok -> maybe_emit_verdict(source, row, verdict, score, next, config, opts)
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_emit_verdict(source, row, verdict, score, consecutive, config, opts) do
    if surfaces?(row, verdict, config) and emit_verdicts?(opts) do
      emitter = Keyword.get(opts, :verdict_emitter, VerdictEmitter)
      attrs = verdict_attrs(source, row, verdict, score, consecutive, config, opts)

      case emitter.emit(attrs, opts) do
        :ok ->
          :ok

        other ->
          Logger.warning("Seasonal disposition verdict emit failed: #{inspect(other)}",
            series_key: row.series_key,
            reason: inspect(other)
          )

          :ok
      end
    else
      :ok
    end
  end

  defp verdict_attrs(%Source{} = source, row, verdict, score, consecutive, config, opts) do
    %{
      series_key: row.series_key,
      resource_type: source.resource_type,
      resource_id: resource_id(row),
      resource_label: row.label,
      metric_class: source.metric_class,
      metric_name: source.metric_name,
      disposition: disposition_tag(verdict),
      status: status(row, verdict, config),
      score: score,
      consecutive_anomalous: consecutive,
      dow: row.dow,
      hod: row.hod,
      sample_value: row.sample_value,
      evaluated_at: Keyword.fetch!(opts, :evaluated_at),
      bucket_started_at: row.bucket_started_at,
      bucket_ended_at: row.bucket_ended_at,
      metadata: %{
        "source" => source.name,
        "robust_statistic" => Atom.to_string(source.robust_statistic),
        "verdict_source" => "central-seasonal"
      }
    }
  end

  # --- NIF call (typed ABI, timed) ---

  defp dispose_batch(inputs, opts) do
    reasoner = Keyword.get(opts, :reasoner, CausalReasoner)
    started = System.monotonic_time(:microsecond)

    try do
      results = reasoner.dispose_batch(:seasonal, inputs)
      elapsed = System.monotonic_time(:microsecond) - started
      {:ok, results, elapsed}
    rescue
      error -> {:error, {:nif_call_failed, Exception.message(error)}}
    catch
      # `rescue` already covers :error-class failures (ErlangError / nif_not_loaded);
      # catch a NIF process :exit, the one mode it doesn't, instead of a dead :error clause.
      :exit, reason -> {:error, {:nif_call_failed, {:exit, reason}}}
    end
  end

  # --- carried state (consecutive_anomalous per (series_key, dow, hod)) ---

  defp state_key(row), do: {row.series_key, row.dow, row.hod}

  defp load_consecutive(source, row, opts) do
    loader = Keyword.get(opts, :state_loader)

    if is_function(loader, 1) do
      loader.(state_key(row)) || 0
    else
      Map.get(carried_overrides(source, opts), state_key(row), 0)
    end
  end

  defp carried_overrides(_source, opts) do
    case Keyword.get(opts, :carried_state) do
      %{} = carried -> carried
      _ -> %{}
    end
  end

  defp persist_state(_source, row, next, opts) do
    case Keyword.get(opts, :state_persister) do
      persister when is_function(persister, 2) -> persister.(state_key(row), next)
      _ -> :ok
    end
  end

  # --- row hydration (SQL profile row -> SeasonalRow inputs) ---

  defp seasonal_row(raw, %Source{} = source, _config) do
    with %{} = raw <- raw,
         series_key when is_binary(series_key) <- string_value(raw, source.series_field),
         dow when is_integer(dow) <- integer_value(raw, source.dow_field),
         hod when is_integer(hod) <- integer_value(raw, source.hod_field),
         sample when is_number(sample) <- number_value(raw, source.sample_field) do
      bucket_started_at = datetime_value(raw, source.bucket_field)

      %{
        series_key: series_key,
        dow: dow,
        hod: hod,
        sample_value: sample * 1.0,
        bucket_count: integer_value(raw, source.count_field) || 0,
        bucket_sum: number_value(raw, source.sum_field) || 0.0,
        bucket_sum_sq: number_value(raw, source.sum_sq_field) || 0.0,
        center: number_value(raw, source.center_field) || 0.0,
        mad: number_value(raw, source.mad_field) || 0.0,
        p05: number_value(raw, source.p05_field) || 0.0,
        p95: number_value(raw, source.p95_field) || 0.0,
        label: label(raw, source, series_key),
        bucket_started_at: bucket_started_at,
        bucket_ended_at: bucket_ended_at(bucket_started_at),
        consecutive_anomalous: 0,
        baseline_excludes_latest: Source.robust?(source)
      }
    else
      _ -> nil
    end
  end

  defp bucket_ended_at(%DateTime{} = bucket_started_at),
    do: DateTime.add(bucket_started_at, 3_600, :second)

  defp bucket_ended_at(_bucket_started_at), do: nil

  # Build the typed NIF row map (the inner `row` of `{:seasonal, %{config, row}}`).
  # `baseline_excludes_latest` is true only for the robust statistics, whose order
  # stats SQL already excludes; the mean/stddev path de-aggregates the latest sample
  # algebraically inside the kernel.
  defp row_struct(row) do
    %{
      series_key: row.series_key,
      dow: row.dow,
      hod: row.hod,
      sample_value: row.sample_value,
      bucket_count: row.bucket_count,
      bucket_sum: row.bucket_sum,
      bucket_sum_sq: row.bucket_sum_sq,
      center: row.center,
      mad: row.mad,
      p05: row.p05,
      p95: row.p95,
      consecutive_anomalous: row.consecutive_anomalous,
      baseline_excludes_latest: row.baseline_excludes_latest
    }
  end

  defp seasonal_config(%Source{} = source, opts) do
    overrides = metric_class_override(opts, source.metric_class)

    %{
      seasonal_n_sigma:
        overrides
        |> option_number("seasonal_n_sigma", Keyword.get(opts, :seasonal_n_sigma))
        |> positive_number(@default_n_sigma),
      min_bucket_samples:
        overrides
        |> option_number("min_bucket_samples", Keyword.get(opts, :min_bucket_samples))
        |> positive_integer(@default_min_bucket_samples),
      confirm_slots:
        overrides
        |> option_number("confirm_slots", Keyword.get(opts, :confirm_slots))
        |> positive_integer(@default_confirm_slots),
      robust_statistic: source.robust_statistic
    }
  end

  # --- result classification + telemetry ---

  defp classify({:error, _}), do: :errored
  defp classify({:ok, %{disposition: {:seasonal_breach, _}}}), do: :breached
  defp classify({:ok, %{disposition: {:seasonal_drift, _}}}), do: :pending
  defp classify({:ok, %{disposition: :insufficient_seasonal_baseline}}), do: :insufficient
  defp classify({:ok, %{disposition: :suppress}}), do: :suppressed
  defp classify({:ok, %{disposition: {:skipped, _}}}), do: :skipped
  defp classify(_), do: :other

  defp surfaces?(_row, {:seasonal_breach, _}, _config), do: true
  defp surfaces?(row, :suppress, config), do: previously_confirmed?(row, config)
  defp surfaces?(_row, _verdict, _config), do: false

  defp status(_row, {:seasonal_breach, _}, _config), do: "breach"

  defp status(row, :suppress, config) do
    if previously_confirmed?(row, config), do: "cleared", else: "suppressed"
  end

  defp status(_row, _verdict, _config), do: "suppressed"

  defp previously_confirmed?(row, %{confirm_slots: confirm_slots}) do
    row.consecutive_anomalous >= max(confirm_slots, 1)
  end

  defp disposition_tag({:seasonal_breach, _}), do: "seasonal_breach"
  defp disposition_tag({:seasonal_drift, _}), do: "seasonal_drift"
  defp disposition_tag(:suppress), do: "suppress"
  defp disposition_tag(:insufficient_seasonal_baseline), do: "insufficient_seasonal_baseline"
  defp disposition_tag({:skipped, _}), do: "skipped"
  defp disposition_tag(_), do: "unknown"

  defp bump(acc, key), do: Map.update(acc, key, 1, &(&1 + 1))

  defp emit_source_telemetry(source, counts, row_count, result, nif_us \\ 0) do
    :telemetry.execute(
      [:serviceradar, :observability, :seasonal_disposition, :source],
      %{
        count: 1,
        rows: non_negative(row_count),
        evaluated: non_negative(row_count),
        breached: count(counts, :breached),
        pending: count(counts, :pending),
        insufficient: count(counts, :insufficient),
        suppressed: count(counts, :suppressed),
        skipped: count(counts, :skipped),
        errored: count(counts, :errored),
        nif_duration_us: non_negative(nif_us)
      },
      %{
        source: source.name,
        metric_class: source.metric_class,
        metric_name: source.metric_name,
        robust_statistic: Atom.to_string(source.robust_statistic),
        result: result
      }
    )

    :ok
  end

  defp emit_source_error_telemetry(%Source{} = source, phase, reason) do
    :telemetry.execute(
      [:serviceradar, :observability, :seasonal_disposition, :source],
      %{count: 1, rows: 0, evaluated: 0, breached: 0, insufficient: 0, nif_duration_us: 0},
      %{
        source: source.name,
        metric_class: source.metric_class,
        metric_name: source.metric_name,
        robust_statistic: Atom.to_string(source.robust_statistic),
        phase: phase,
        result: :error,
        reason_class: reason_class(reason)
      }
    )

    :ok
  end

  defp count(counts, key) when is_map(counts), do: Map.get(counts, key, 0)
  defp count(_counts, _key), do: 0

  defp non_negative(value) when is_integer(value) and value >= 0, do: value
  defp non_negative(value) when is_float(value) and value >= 0, do: value
  defp non_negative(_value), do: 0

  defp reason_class(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_class({reason, _}) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_class(%_{}), do: "exception"
  defp reason_class(_reason), do: "error"

  defp emit_verdicts?(opts), do: Keyword.get(opts, :emit_verdicts?, true)

  # --- paging (mirror CapacityForecasting.Worker.fetch_rows) ---

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
       do: {:error, {:seasonal_disposition_history_pages_exhausted, max_pages}}

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
        {:error, {:unexpected_seasonal_disposition_page, other}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # --- config / opts plumbing ---

  defp sources(opts) do
    opts
    |> Keyword.get(:sources, Source.defaults())
    |> Enum.map(&Source.from_config/1)
  end

  defp metric_class_override(opts, metric_class) do
    opts
    |> Keyword.get(:seasonal_metric_class_overrides, %{})
    |> case do
      overrides when is_map(overrides) ->
        Map.get(overrides, metric_class, Map.get(overrides, to_string(metric_class), %{}))

      _ ->
        %{}
    end
  end

  defp option_number(map, key, default) when is_map(map) do
    Map.get(map, key, Map.get(map, existing_atom(key), default))
  end

  defp option_number(_map, _key, default), do: default

  defp merge_runtime_opts(opts) do
    config()
    |> Keyword.merge(AnomalyConfigRuntime.seasonal_disposition_opts())
    |> Keyword.merge(opts)
  end

  defp config do
    Application.get_env(:serviceradar_core, __MODULE__, [])
  end

  # --- row field helpers ---

  defp resource_id(row), do: row.series_key

  defp label(_raw, %Source{label_fields: []}, series_key), do: series_key

  defp label(raw, %Source{label_fields: fields}, series_key) do
    fields
    |> Enum.map(&string_value(raw, &1))
    |> Enum.reject(&(&1 in [nil, ""]))
    |> case do
      [] -> series_key
      values -> Enum.join(values, " / ")
    end
  end

  defp evaluated_at(%Oban.Job{args: %{"evaluated_at" => iso}}) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> DateTime.truncate(dt, :microsecond)
      _ -> DateTime.truncate(DateTime.utc_now(), :microsecond)
    end
  end

  defp evaluated_at(%Oban.Job{scheduled_at: %DateTime{} = dt}),
    do: DateTime.truncate(dt, :microsecond)

  defp evaluated_at(%Oban.Job{inserted_at: %DateTime{} = dt}),
    do: DateTime.truncate(dt, :microsecond)

  defp evaluated_at(_job), do: DateTime.truncate(DateTime.utc_now(), :microsecond)

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

  defp integer_value(row, field) do
    case value(row, field) do
      value when is_integer(value) -> value
      value when is_float(value) -> trunc(value)
      value when is_binary(value) -> parse_integer(value)
      _ -> nil
    end
  end

  defp parse_integer(value) do
    case Integer.parse(value) do
      {number, ""} -> number
      _ -> nil
    end
  end

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

  defp value(_row, _field), do: nil

  defp existing_atom(field) when is_atom(field), do: field

  defp existing_atom(field) when is_binary(field) do
    String.to_existing_atom(field)
  rescue
    ArgumentError -> :__serviceradar_missing_field__
  end

  defp positive_number(value, _default) when is_number(value) and value > 0, do: value * 1.0
  defp positive_number(_value, default), do: default * 1.0

  defp positive_integer(value, _default) when is_integer(value) and value > 0, do: value

  defp positive_integer(value, _default) when is_float(value) and value > 0, do: trunc(value)

  defp positive_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} when number > 0 -> number
      _ -> default
    end
  end

  defp positive_integer(_value, default), do: default
end
