defmodule ServiceRadar.Jobs.RootSpanRatioWorker do
  @moduledoc """
  Oban cron worker (every 5 minutes, leader-elected via Oban.Plugins.Cron)
  that computes the root-span ratio over the last 15 minutes of
  `otel_traces` as an ingest-health signal.

  A healthy trace pipeline has far more child spans than root spans
  (`parent_span_id IS NULL`). When nearly every span is a root span the
  parent linkage is being lost at ingest (id normalization bugs, producers
  dropping `parent_span_id`, context propagation failures), which silently
  degrades trace assembly.

  Behavior:

  - When total spans in the window are below the configured floor the run
    is a no-op (too little data to judge).
  - When total >= floor, a `[:serviceradar, :observability, :root_span_ratio]`
    gauge is ALWAYS emitted (so dashboards can chart the ratio).
  - When additionally roots/total exceeds the configured threshold, a
    warning is logged.

  Configuration (`config :serviceradar_core, __MODULE__`):

  - `:threshold` — breach threshold, default 0.85
    (env `SERVICERADAR_ROOT_SPAN_RATIO_THRESHOLD`)
  - `:min_spans` — minimum spans in the window before the signal is
    evaluated, default 1000 (env `SERVICERADAR_ROOT_SPAN_RATIO_MIN_SPANS`)

  With StarRocks enabled the spans are stored in the warehouse only, so the
  counts are read there; otherwise from CNPG.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [period: :infinity, states: :incomplete]

  alias Ecto.Adapters.SQL
  alias ServiceRadar.Analytics.StarRocks.Destination
  alias ServiceRadar.Analytics.StarRocks.Env, as: StarRocksEnv
  alias ServiceRadar.Analytics.StarRocks.Query, as: StarRocksQuery

  require Logger

  @window_minutes 15
  @default_min_spans 1000
  @default_threshold 0.85

  @counts_sql """
  SELECT
    count(*)::bigint AS total_spans,
    (count(*) FILTER (WHERE parent_span_id IS NULL))::bigint AS root_spans
  FROM otel_traces
  WHERE timestamp > NOW() - ($1::int * INTERVAL '1 minute')
  """

  @telemetry_event [:serviceradar, :observability, :root_span_ratio]

  def telemetry_event, do: @telemetry_event
  def window_minutes, do: @window_minutes

  @impl Oban.Worker
  def perform(_job) do
    case fetch_counts() do
      {:ok, total, roots} ->
        total
        |> evaluate(roots, min_spans(), threshold())
        |> publish(total, roots)

      :skip ->
        :ok

      {:error, error} ->
        Logger.error("Failed to compute root span ratio: #{describe(error)}")
        {:error, error}
    end
  end

  @doc """
  Pure decision function for the root-span-ratio health signal.

  Returns:

  - `:skip` when `total` is below the floor (not enough data)
  - `{:ok, ratio}` when the ratio should be charted but is healthy
  - `{:breach, ratio}` when the ratio exceeds the threshold
  """
  @spec evaluate(non_neg_integer(), non_neg_integer(), pos_integer(), float()) ::
          :skip | {:ok, float()} | {:breach, float()}
  def evaluate(total, _roots, min_spans, _threshold) when total < min_spans, do: :skip

  def evaluate(total, roots, _min_spans, threshold) do
    ratio = roots / total

    if ratio > threshold do
      {:breach, ratio}
    else
      {:ok, ratio}
    end
  end

  defp publish(:skip, _total, _roots), do: :ok

  defp publish({outcome, ratio}, total, roots) do
    threshold = threshold()

    :telemetry.execute(
      @telemetry_event,
      %{ratio: ratio, total_spans: total, root_spans: roots},
      %{threshold: threshold, window_minutes: @window_minutes}
    )

    if outcome == :breach do
      Logger.warning(
        "Root span ratio breach: #{Float.round(ratio, 4)} of spans in the last " <>
          "#{@window_minutes}m are root spans (threshold #{threshold}); parent " <>
          "span linkage is likely being lost at ingest",
        root_span_ratio: ratio,
        total_spans: total,
        root_spans: roots,
        threshold: threshold,
        window_minutes: @window_minutes
      )
    end

    :ok
  end

  @doc false
  # The warehouse form of @counts_sql. The Frontend evaluates NOW() in its own
  # time zone while spans are stored in UTC, so the cutoff is a UTC literal.
  @spec warehouse_counts_sql(DateTime.t()) :: String.t()
  def warehouse_counts_sql(now) do
    cutoff =
      now
      |> DateTime.add(-@window_minutes * 60, :second)
      |> DateTime.to_naive()
      |> NaiveDateTime.truncate(:second)
      |> NaiveDateTime.to_string()

    "SELECT COUNT(*) AS total_spans, " <>
      "SUM(CASE WHEN parent_span_id IS NULL THEN 1 ELSE 0 END) AS root_spans " <>
      "FROM #{StarRocksEnv.table("otel_traces")} WHERE `timestamp` > '#{cutoff}'"
  end

  defp fetch_counts do
    if Destination.enabled?(), do: fetch_warehouse_counts(), else: fetch_cnpg_counts()
  end

  defp fetch_warehouse_counts do
    case StarRocksQuery.execute(warehouse_counts_sql(DateTime.utc_now()), timeout: 30_000) do
      {:ok, %{rows: [[total, roots]]}} when is_integer(total) ->
        {:ok, total, roots || 0}

      {:ok, _result} ->
        :skip

      {:error, error} ->
        {:error, error}
    end
  end

  defp fetch_cnpg_counts do
    case SQL.query(ServiceRadar.Repo, @counts_sql, [@window_minutes], timeout: 30_000) do
      {:ok, %{rows: [[total, roots]]}} when is_integer(total) and is_integer(roots) ->
        {:ok, total, roots}

      {:ok, _result} ->
        :skip

      {:error, %Postgrex.Error{postgres: %{code: :undefined_table}}} ->
        Logger.debug("otel_traces table missing; skipping root span ratio check")
        :skip

      {:error, error} ->
        {:error, error}
    end
  end

  defp describe(error) when is_exception(error), do: Exception.message(error)
  defp describe(error), do: inspect(error)

  defp threshold do
    :serviceradar_core
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:threshold, @default_threshold)
    |> valid_threshold(@default_threshold)
  end

  defp min_spans do
    :serviceradar_core
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:min_spans, @default_min_spans)
    |> positive_integer(@default_min_spans)
  end

  defp valid_threshold(value, _default) when is_float(value) and value > 0.0 and value <= 1.0,
    do: value

  defp valid_threshold(_value, default), do: default

  defp positive_integer(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value, default), do: default
end
