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
    3. Call `DispositionKernels.dispose_batch(:seasonal, rows)` once per source — the NIF
       moves only residual-z, breach, baseline-sufficiency, and robust-statistic
       selection; every gate is a typed `Disposition` value, never an unwind.
    4. Persist the returned `next_consecutive_anomalous` per `(series_key, dow, hod)`
       and emit `verdict_source: central-seasonal` verdicts for confirmed breaches
       and confirmed-breach clears via the existing `VerdictEmitter` onto the signal path.

  Mirrors `ServiceRadar.Observability.CapacityForecasting.Worker`. Tests can inject
  `:runner`, `:sources`, `:reasoner`, `:state_loader`, `:state_persister`, and
  `:verdict_emitter`; production uses `SRQLRunner`, the `DispositionKernels` NIF facade,
  and the Postgres-backed seasonal state store.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [
      period: :infinity,
      states: :incomplete,
      keys: [:trigger]
    ]

  alias ServiceRadar.Observability.AnomalyConfigRuntime
  alias ServiceRadar.Observability.DispositionKernels
  alias ServiceRadar.Observability.PagedQuery
  alias ServiceRadar.Observability.SeasonalDisposition.Source
  alias ServiceRadar.Observability.SeasonalDisposition.StateStore
  alias ServiceRadar.Observability.SeasonalDisposition.VerdictEmitter
  alias ServiceRadar.Observability.SRQLRunner
  alias ServiceRadar.SweepJobs.ObanSupport

  require Logger

  @default_n_sigma 3.0
  @default_min_bucket_samples 4
  # Default = 2 (1.16 / D-Q3): light hysteresis so a single noisy hourly bucket is a
  # pending drift, not an immediate breach. Operator-tunable down to 1 or higher.
  @default_confirm_slots 2

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

      case assert_nif_liveness(opts) do
        :ok ->
          opts
          |> sources()
          |> Enum.reduce_while(:ok, fn source, :ok ->
            case refresh_source(source, opts) do
              :ok -> {:cont, :ok}
              {:error, reason} -> {:halt, {:error, reason}}
            end
          end)

        {:error, reason} ->
          {:error, reason}
      end
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

  @doc """
  Fetch + hydrate the hour-of-week profile rows for one source into the
  `EdgeBaseline.build/2` input shape (the same typed `{series_key, dow, hod,
  center/mad/p05/p95/bucket_*}` rows the disposition path hydrates), WITHOUT
  loading the carried-hysteresis state the verdict pass needs.

  The edge-baseline producer reduces these rows to the compact per-series
  `seasonal_baselines` payload pushed core->edge, so it reuses the exact SRQL fetch
  + row hydration the disposition verdict pass uses — there is only one definition
  of how a profile row maps to the robust order statistics.
  """
  @spec edge_baseline_rows(Source.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def edge_baseline_rows(%Source{} = source, opts \\ []) do
    opts = merge_runtime_opts(opts)
    runner = Keyword.get(opts, :runner, SRQLRunner)
    runner_opts = Keyword.get(opts, :runner_opts, [])
    config = seasonal_config(source, opts)

    # The edge detector buckets hour-of-week in UTC (anomaly-core `hour_of_week`), so the
    # delivered baseline must be UTC-bucketed too — independent of the source's configured
    # `profile_timezone` (which the central VERDICT pass keeps for local-hour bucketing).
    # A non-UTC profile would otherwise build local-tz (dow,hod) buckets that resolve
    # nothing against the edge's UTC clock.
    case fetch_rows(runner, edge_baseline_query(source), runner_opts, opts) do
      {:ok, raw_rows} ->
        rows =
          raw_rows
          |> Enum.map(&unwrap_payload/1)
          |> Enum.map(&seasonal_row(&1, source, config))
          |> Enum.reject(&is_nil/1)

        {:ok, rows}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Force the edge-baseline fetch to UTC so the (dow,hod) buckets align with the edge's
  # UTC hour-of-week. The central disposition verdict pass keeps the configured tz via
  # `source.query`. We must ALWAYS end up with `timezone:"Etc/UTC"`: rewrite an existing
  # `timezone:"..."` literal when present, but APPEND it when the source query carries no
  # timezone term — a plain `Regex.replace` silently no-ops on a tz-less query and would
  # leave the baseline on the SRQL default (implicit) timezone.
  @timezone_literal ~r/timezone:"[^"]*"/
  @utc_timezone_term ~s|timezone:"Etc/UTC"|

  defp edge_baseline_query(%Source{query: query}) when is_binary(query) do
    if Regex.match?(@timezone_literal, query) do
      Regex.replace(@timezone_literal, query, @utc_timezone_term)
    else
      String.trim_trailing(query) <> " " <> @utc_timezone_term
    end
  end

  defp edge_baseline_query(%Source{query: query}), do: query

  # The SRQL `profile_hour_of_week` route returns one `jsonb_build_object(...)`
  # column, so `SRQLRunner` rows arrive as `%{"payload" => %{...}}`. Flatten that to
  # the top-level field map `seasonal_row/3` reads. Rows already flat (the injected
  # test runners) pass through unchanged.
  defp unwrap_payload(%{"payload" => %{} = payload} = row) when map_size(row) == 1, do: payload
  defp unwrap_payload(row), do: row

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

    case profile_rows(source, raw_rows, config, opts) do
      {:ok, []} ->
        emit_source_telemetry(source, [], 0, :ok)
        :ok

      {:ok, rows} ->
        inputs = Enum.map(rows, &{:seasonal, %{config: config, row: row_struct(&1)}})

        case dispose_batch(inputs, opts) do
          {:ok, results, nif_us} ->
            handle_results(source, rows, results, config, nif_us, opts)

          {:error, reason} ->
            emit_source_error_telemetry(source, :nif, reason)
            {:error, reason}
        end

      {:error, reason} ->
        Logger.warning("Seasonal disposition profile rows missing required columns",
          source: source.name,
          reason: inspect(reason)
        )

        emit_source_error_telemetry(source, :profile, reason)
        {:error, reason}
    end
  end

  defp profile_rows(%Source{} = source, raw_rows, config, opts) when is_list(raw_rows) do
    hydrated_rows =
      raw_rows
      # Live `SRQLRunner` wraps each profile_hour_of_week row as `%{"payload" => %{...}}`
      # (jsonb_build_object); the dispose path must flatten it before `seasonal_row`
      # reads the top-level fields — otherwise it hydrates nothing against real data
      # (the same envelope `edge_baseline_rows/2` unwraps). Injected/flat rows pass through.
      |> Enum.map(&unwrap_payload/1)
      |> Enum.map(&seasonal_row(&1, source, config))
      |> Enum.reject(&is_nil/1)

    cond do
      hydrated_rows != [] ->
        hydrate_state(source, hydrated_rows, opts)

      raw_rows == [] ->
        {:ok, []}

      true ->
        {:error, {:seasonal_profile_columns_missing, missing_profile_fields(source, raw_rows)}}
    end
  end

  defp missing_profile_fields(%Source{} = source, raw_rows) do
    required_fields = required_profile_fields(source)

    present_fields =
      raw_rows
      |> Enum.filter(&is_map/1)
      |> Enum.flat_map(&Map.keys/1)
      |> MapSet.new(&to_string/1)

    Enum.reject(required_fields, &MapSet.member?(present_fields, &1))
  end

  defp required_profile_fields(%Source{robust_statistic: :mean_stddev} = source) do
    [
      source.series_field,
      source.dow_field,
      source.hod_field,
      source.sample_field,
      source.bucket_field,
      source.count_field,
      source.sum_field,
      source.sum_sq_field
    ]
  end

  defp required_profile_fields(%Source{robust_statistic: :median_mad} = source) do
    [
      source.series_field,
      source.dow_field,
      source.hod_field,
      source.sample_field,
      source.bucket_field,
      source.count_field,
      source.center_field,
      source.mad_field
    ]
  end

  defp required_profile_fields(%Source{robust_statistic: :p05p95} = source) do
    [
      source.series_field,
      source.dow_field,
      source.hod_field,
      source.sample_field,
      source.bucket_field,
      source.count_field,
      source.center_field,
      source.p05_field,
      source.p95_field
    ]
  end

  defp handle_results(%Source{} = source, rows, results, config, nif_us, opts) do
    pairs = Enum.zip(rows, results)
    {:ok, actions, counts} = build_result_actions(pairs, config)

    case persist_states(source, actions, opts) do
      :ok ->
        Enum.each(actions, fn action ->
          maybe_emit_verdict(
            source,
            action.row,
            action.verdict,
            action.score,
            action.consecutive_anomalous,
            config,
            opts
          )
        end)

        emit_source_telemetry(source, counts, length(rows), :ok, nif_us)
        :ok

      {:error, reason} ->
        emit_source_error_telemetry(source, :persist, reason)
        {:error, reason}
    end
  end

  defp build_result_actions(pairs, config) do
    {actions, counts} =
      Enum.reduce(pairs, {[], %{}}, fn {row, result}, {actions, counts} ->
        counts = bump(counts, classify(result))

        case result_action(row, result, config) do
          {:ok, nil} -> {actions, counts}
          {:ok, action} -> {[action | actions], counts}
        end
      end)

    {:ok, Enum.reverse(actions), counts}
  end

  defp result_action(_row, {:error, reason}, _config) do
    Logger.warning("Seasonal disposition row errored", reason: inspect(reason))
    {:ok, nil}
  end

  defp result_action(row, {:ok, disposition}, config) do
    next = Map.get(disposition, :next_consecutive_anomalous, 0)
    score = Map.get(disposition, :score, 0.0)
    verdict = Map.get(disposition, :disposition)

    {:ok,
     %{
       key: state_key(row),
       row: row,
       verdict: verdict,
       score: score,
       disposition: persisted_disposition_tag(verdict),
       status: persisted_status(row, verdict, config),
       consecutive_anomalous: next,
       bucket_started_at: row.bucket_started_at,
       bucket_ended_at: row.bucket_ended_at
     }}
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

  defp assert_nif_liveness(opts) do
    case safe_dispose_batch(:seasonal, [], opts) do
      {:ok, []} ->
        emit_nif_liveness_telemetry(:ok, nil)
        :ok

      {:ok, other} ->
        reason = {:unexpected_liveness_result, other}
        emit_nif_liveness_telemetry(:degraded, reason)
        {:error, {:seasonal_nif_unavailable, reason}}

      {:error, reason} ->
        Logger.error("Seasonal disposition NIF liveness probe failed",
          reason: inspect(reason)
        )

        emit_nif_liveness_telemetry(:degraded, reason)
        {:error, {:seasonal_nif_unavailable, reason}}
    end
  end

  defp dispose_batch(inputs, opts) do
    started = System.monotonic_time(:microsecond)

    case safe_dispose_batch(:seasonal, inputs, opts) do
      {:ok, results} ->
        elapsed = System.monotonic_time(:microsecond) - started
        {:ok, results, elapsed}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp safe_dispose_batch(kind, inputs, opts) do
    reasoner = Keyword.get(opts, :reasoner, DispositionKernels)

    try do
      {:ok, reasoner.dispose_batch(kind, inputs)}
    rescue
      error -> {:error, {:nif_call_failed, Exception.message(error)}}
    catch
      # `rescue` already covers :error-class failures (ErlangError / nif_not_loaded);
      # catch a NIF process :exit, the one mode it doesn't, instead of a dead :error clause.
      :exit, reason -> {:error, {:nif_call_failed, {:exit, reason}}}
    end
  end

  defp emit_nif_liveness_telemetry(status, reason) do
    :telemetry.execute(
      [:serviceradar, :observability, :seasonal_disposition, :nif_liveness],
      %{count: 1},
      %{
        status: status,
        reason_class: reason_class(reason)
      }
    )
  end

  # --- carried state (consecutive_anomalous per (series_key, dow, hod)) ---

  defp state_key(row), do: {row.series_key, row.dow, row.hod}

  defp hydrate_state(source, rows, opts) do
    with {:ok, states} <- load_state_map(source, rows, opts) do
      {:ok,
       Enum.map(rows, fn row ->
         %{row | consecutive_anomalous: Map.get(states, state_key(row), 0)}
       end)}
    end
  end

  defp load_state_map(source, rows, opts) do
    loader = Keyword.get(opts, :state_loader)

    cond do
      is_function(loader, 1) ->
        {:ok, Map.new(rows, fn row -> {state_key(row), loader.(state_key(row)) || 0} end)}

      Keyword.has_key?(opts, :carried_state) ->
        carried = carried_overrides(source, opts)
        {:ok, Map.take(carried, Enum.map(rows, &state_key/1))}

      true ->
        state_store = Keyword.get(opts, :state_store, StateStore)
        state_store.load_many(source, Enum.map(rows, &state_key/1), opts)
    end
  end

  defp carried_overrides(_source, opts) do
    case Keyword.get(opts, :carried_state) do
      %{} = carried -> carried
      _ -> %{}
    end
  end

  defp persist_states(source, actions, opts) do
    actions = attach_evaluation_context(actions, opts)

    case Keyword.get(opts, :state_persister) do
      persister when is_function(persister, 2) ->
        Enum.reduce_while(actions, :ok, fn action, :ok ->
          case persister.(action.key, action.consecutive_anomalous) do
            :ok -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, reason}}
            other -> {:halt, {:error, {:seasonal_state_persist_failed, other}}}
          end
        end)

      _ ->
        state_store = Keyword.get(opts, :state_store, StateStore)
        state_store.persist_many(source, actions, opts)
    end
  end

  defp attach_evaluation_context(actions, opts) do
    evaluated_at = Keyword.get(opts, :evaluated_at)

    Enum.map(actions, fn action ->
      Map.put_new(action, :evaluated_at, evaluated_at)
    end)
  end

  # --- row hydration (SQL profile row -> SeasonalRow inputs) ---

  defp seasonal_row(raw, %Source{} = source, _config) do
    with %{} = raw <- raw,
         series_key when is_binary(series_key) <- string_value(raw, source.series_field),
         dow when is_integer(dow) <- integer_value(raw, source.dow_field),
         hod when is_integer(hod) <- integer_value(raw, source.hod_field),
         sample when is_number(sample) <- number_value(raw, source.sample_field),
         %{} = profile <- profile_stats(raw, source) do
      bucket_started_at = datetime_value(raw, source.bucket_field)

      %{
        series_key: series_key,
        dow: dow,
        hod: hod,
        sample_value: sample * 1.0,
        bucket_count: profile.bucket_count,
        bucket_sum: Map.get(profile, :bucket_sum, 0.0),
        bucket_sum_sq: Map.get(profile, :bucket_sum_sq, 0.0),
        center: Map.get(profile, :center, 0.0),
        mad: Map.get(profile, :mad, 0.0),
        p05: Map.get(profile, :p05, 0.0),
        p95: Map.get(profile, :p95, 0.0),
        partition: string_value(raw, "partition"),
        agent_uid: string_value(raw, "agent_uid"),
        agent_id: string_value(raw, "agent_id"),
        target_device_ip: string_value(raw, "target_device_ip"),
        metric_name: string_value(raw, "metric_name"),
        if_index: integer_value(raw, "if_index"),
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

  defp profile_stats(raw, %Source{robust_statistic: :mean_stddev} = source) do
    with count when is_integer(count) <- integer_value(raw, source.count_field),
         sum when is_number(sum) <- number_value(raw, source.sum_field),
         sum_sq when is_number(sum_sq) <- number_value(raw, source.sum_sq_field) do
      %{bucket_count: count, bucket_sum: sum * 1.0, bucket_sum_sq: sum_sq * 1.0}
    else
      _ -> nil
    end
  end

  defp profile_stats(raw, %Source{robust_statistic: :median_mad} = source) do
    case integer_value(raw, source.count_field) do
      count when is_integer(count) ->
        center = number_value(raw, source.center_field)
        mad = number_value(raw, source.mad_field)

        cond do
          is_number(center) and is_number(mad) ->
            %{bucket_count: count, center: center * 1.0, mad: mad * 1.0}

          null_fields?(raw, [source.center_field, source.mad_field]) ->
            %{bucket_count: count, center: 0.0, mad: 0.0}

          true ->
            nil
        end

      _ ->
        nil
    end
  end

  defp profile_stats(raw, %Source{robust_statistic: :p05p95} = source) do
    case integer_value(raw, source.count_field) do
      count when is_integer(count) ->
        center = number_value(raw, source.center_field)
        p05 = number_value(raw, source.p05_field)
        p95 = number_value(raw, source.p95_field)

        cond do
          is_number(center) and is_number(p05) and is_number(p95) ->
            %{bucket_count: count, center: center * 1.0, p05: p05 * 1.0, p95: p95 * 1.0}

          null_fields?(raw, [source.center_field, source.p05_field, source.p95_field]) ->
            %{bucket_count: count, center: 0.0, p05: 0.0, p95: 0.0}

          true ->
            nil
        end

      _ ->
        nil
    end
  end

  defp null_fields?(raw, fields) do
    Enum.all?(fields, fn field ->
      present_field?(raw, field) and is_nil(value(raw, field))
    end)
  end

  defp present_field?(raw, field) when is_map(raw) do
    Map.has_key?(raw, field) or Map.has_key?(raw, existing_atom(field))
  rescue
    ArgumentError -> false
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

  defp persisted_disposition_tag(:suppress), do: "normal"
  defp persisted_disposition_tag(verdict), do: disposition_tag(verdict)

  defp persisted_status(row, :suppress, config) do
    if previously_confirmed?(row, config), do: "cleared", else: "normal"
  end

  defp persisted_status(_row, {:seasonal_drift, _}, _config), do: "pending"
  defp persisted_status(_row, :insufficient_seasonal_baseline, _config), do: "insufficient"
  defp persisted_status(_row, {:skipped, _}, _config), do: "skipped"
  defp persisted_status(row, verdict, config), do: status(row, verdict, config)

  defp bump(acc, key), do: Map.update(acc, key, 1, &(&1 + 1))

  defp emit_source_telemetry(source, counts, row_count, result, nif_us \\ 0) do
    :telemetry.execute(
      [:serviceradar, :observability, :seasonal_disposition, :source],
      %{
        count: 1,
        rows: non_negative(row_count),
        evaluated: non_negative(row_count),
        covered: seasonal_covered_count(counts, row_count),
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
      %{
        count: 1,
        rows: 0,
        evaluated: 0,
        covered: 0,
        breached: 0,
        insufficient: 0,
        nif_duration_us: 0
      },
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

  defp seasonal_covered_count(counts, row_count) do
    row_count
    |> Kernel.-(count(counts, :insufficient))
    |> Kernel.-(count(counts, :errored))
    |> non_negative()
  end

  defp non_negative(value) when is_integer(value) and value >= 0, do: value
  defp non_negative(value) when is_number(value) and value >= 0, do: value
  defp non_negative(_value), do: 0

  defp reason_class(nil), do: nil
  defp reason_class(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_class({reason, _}) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_class(%_{}), do: "exception"
  defp reason_class(_reason), do: "error"

  defp emit_verdicts?(opts), do: Keyword.get(opts, :emit_verdicts?, true)

  defp fetch_rows(runner, query, runner_opts, opts) do
    if function_exported?(runner, :query_page, 2) do
      PagedQuery.fetch(
        runner,
        query,
        runner_opts,
        opts,
        [],
        fn rows_acc, rows -> Enum.reverse(rows, rows_acc) end,
        &Enum.reverse/1,
        fn max_pages -> {:seasonal_disposition_history_pages_exhausted, max_pages} end,
        fn other -> {:unexpected_seasonal_disposition_page, other} end
      )
    else
      runner.query(query, runner_opts)
    end
  end

  # --- config / opts plumbing ---

  defp sources(opts) do
    sources =
      case Keyword.fetch(opts, :sources) do
        {:ok, sources} -> sources
        :error -> Source.defaults(opts)
      end

    sources
    |> Enum.map(&Source.from_config/1)
    |> Enum.filter(&supported_source?/1)
  end

  defp supported_source?(%Source{} = source) do
    if Source.seasonal_disposition_supported?(source) do
      true
    else
      Logger.info("Skipping unsupported seasonal disposition source",
        source: source.name,
        metric_class: source.metric_class,
        metric_name: source.metric_name
      )

      :telemetry.execute(
        [:serviceradar, :observability, :seasonal_disposition, :source_skipped],
        %{count: 1},
        %{
          source: source.name,
          metric_class: source.metric_class,
          metric_name: source.metric_name,
          reason: :unsupported_metric_class
        }
      )

      false
    end
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
