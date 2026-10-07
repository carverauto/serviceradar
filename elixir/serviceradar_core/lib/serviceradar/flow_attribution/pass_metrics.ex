defmodule ServiceRadar.FlowAttribution.PassMetrics do
  @moduledoc """
  Correlator health as metrics, published through JetStream like every other
  metric: a ServiceRadar metric envelope (`serviceradar.metric.v1`) on
  `metrics.flow_attribution`, persisted by EventWriter's `Metrics` processor.

  After each pass, successful or not, `report/4` publishes:

    * `flow_attribution_pass_duration_ms`, tagged `outcome` (`ok` or `error`)
    * `flow_attribution_flows_read` - unattributed flows in the pass window
    * `flow_attribution_matches`, tagged `strategy` (by match rank)
    * `flow_attribution_stamped`
    * `flow_attribution_observation_lag_seconds` - age of the newest observation
    * `flow_attribution_observation_ingest_rate` - observations per second over
      the last pass interval
    * `flow_attribution_live_partitions` - daily partitions of the observation table
    * `flow_attribution_diagnostic`, tagged `outcome`, value 1. This tag is
      separate from the duration metric's `ok` or `error` tag. Outcomes are
      `attributed`, `candidate_unstamped`, `no_producer_rows`,
      `no_sampled_flows`, `no_topology_overlap`, `no_tuple_candidate`, and
      `error`. A quiet pass whose readings are missing omits the diagnostic
      rather than guessing.

  The warehouse readings come from small bounded queries; one that fails is left
  out of the batch rather than failing the report. A failed report is logged and
  never affects the pass.
  """

  alias ServiceRadar.Analytics.StarRocks.Env
  alias ServiceRadar.Analytics.StarRocks.Query
  alias ServiceRadar.FlowAttribution.Correlation
  alias Serviceradar.Metric.V1.IngestIdentity
  alias Serviceradar.Metric.V1.Metric
  alias Serviceradar.Metric.V1.MetricBatch
  alias Serviceradar.Metric.V1.MetricPoint
  alias Serviceradar.Metric.V1.MetricResource
  alias Serviceradar.Metric.V1.StringMapEntry
  alias ServiceRadar.NATS.JetStreamPublish

  require Logger

  @subject "metrics.flow_attribution"
  @observations_table "flow_process_attribution_observations"
  @ingest_window_seconds 120

  @strategies %{
    0 => "exact",
    1 => "listener_or_relaxed",
    2 => "node_snat",
    3 => "public_endpoint",
    4 => "public_endpoint",
    5 => "public_endpoint"
  }

  @spec subject() :: String.t()
  def subject, do: @subject

  @doc """
  Publishes one pass's metrics. `result` is the pass result, `duration_ms` its
  wall time and `matches_by_rank` what `Correlation.run_pass/1` returned.

  Options (tests): `:query` (StarRocks, `sql -> result`), `:publish`
  (`(subject, body) -> :ok | {:error, term}`) and `:now` (`DateTime`).
  """
  @spec report(term(), non_neg_integer(), map(), keyword()) :: :ok | {:error, term()}
  def report(result, duration_ms, matches_by_rank, opts \\ []) do
    query = Keyword.get(opts, :query, &Query.execute/1)
    publish = Keyword.get(opts, :publish, &JetStreamPublish.publish/2)
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    {reading_metrics, counts} = readings(query, result, matches_by_rank)

    body =
      result
      |> metrics(duration_ms, matches_by_rank, reading_metrics, counts)
      |> batch(now)
      |> MetricBatch.encode()

    case publish.(@subject, body) do
      :ok ->
        :ok

      {:error, reason} = error ->
        Logger.warning("FlowAttribution pass metrics publish failed: #{inspect(reason)}")
        error
    end
  rescue
    error ->
      Logger.warning("FlowAttribution pass metrics failed: #{Exception.message(error)}")
      {:error, error}
  end

  defp metrics(result, duration_ms, matches_by_rank, reading_metrics, counts) do
    outcome = if match?({:ok, _}, result), do: "ok", else: "error"

    matches =
      matches_by_rank
      |> Enum.group_by(fn {rank, _count} -> Map.get(@strategies, rank, "other") end)
      |> Enum.map(fn {strategy, grouped} ->
        {"flow_attribution_matches", Enum.sum(Enum.map(grouped, &elem(&1, 1))),
         %{"strategy" => strategy}}
      end)

    stamped =
      case result do
        {:ok, count} when is_integer(count) -> [{"flow_attribution_stamped", count, %{}}]
        _ -> []
      end

    diagnostic =
      case diagnostic_outcome(result, matches_by_rank, counts) do
        nil -> []
        name -> [{"flow_attribution_diagnostic", 1, %{"outcome" => name}}]
      end

    [{"flow_attribution_pass_duration_ms", duration_ms, %{"outcome" => outcome}}] ++
      matches ++ stamped ++ reading_metrics ++ diagnostic
  end

  # Producer presence is decided before sampled flows, so a pass with neither
  # side is no_producer_rows. Overlap is only read once both sides exist.
  defp diagnostic_outcome({:error, _}, _matches, _counts), do: "error"

  defp diagnostic_outcome({:ok, count}, _matches, _counts) when is_integer(count) and count > 0,
    do: "attributed"

  defp diagnostic_outcome({:ok, 0}, matches, _counts) when map_size(matches) > 0,
    do: "candidate_unstamped"

  defp diagnostic_outcome({:ok, 0}, matches, counts) when map_size(matches) == 0,
    do: empty_outcome(counts)

  defp diagnostic_outcome(_result, _matches, _counts), do: nil

  defp empty_outcome(%{producer: 0}), do: "no_producer_rows"

  defp empty_outcome(%{producer: producer, flows: 0}) when is_integer(producer) and producer > 0,
    do: "no_sampled_flows"

  defp empty_outcome(%{producer: producer, flows: flows, overlap: 0})
       when is_integer(producer) and producer > 0 and is_integer(flows) and flows > 0,
       do: "no_topology_overlap"

  defp empty_outcome(%{producer: producer, flows: flows, overlap: overlap})
       when is_integer(producer) and producer > 0 and is_integer(flows) and flows > 0 and
              is_integer(overlap) and
              overlap > 0,
       do: "no_tuple_candidate"

  defp empty_outcome(_counts), do: nil

  defp readings(query, result, matches_by_rank) do
    flows_table = Env.table("ocsf_network_activity")
    observations_table = Env.table(@observations_table)
    [database, table] = String.split(observations_table, ".", parts: 2)

    flows_read = """
    SELECT COUNT(*) FROM (
      SELECT id FROM #{flows_table}
      WHERE `time` > DATE_SUB(UTC_TIMESTAMP(), INTERVAL #{Correlation.flows_window_minutes()} MINUTE)
        AND pid IS NULL
      LIMIT #{Correlation.batch_limit()}
    ) AS f
    """

    observations = """
    SELECT seconds_diff(UTC_TIMESTAMP(), MAX(observed_at)),
           SUM(IF(observed_at > DATE_SUB(UTC_TIMESTAMP(), INTERVAL #{@ingest_window_seconds} SECOND), 1, 0))
    FROM #{observations_table}
    WHERE observed_at > DATE_SUB(UTC_TIMESTAMP(), INTERVAL #{Correlation.observations_window_seconds()} SECOND)
    """

    partitions = """
    SELECT COUNT(*) FROM information_schema.partitions_meta
    WHERE DB_NAME = #{Correlation.literal(database)} AND TABLE_NAME = #{Correlation.literal(table)}
      AND PARTITION_NAME NOT LIKE '$%'
    """

    flows_row = one_row(query, flows_read)
    observations_row = one_row(query, observations)
    partitions_row = one_row(query, partitions)
    flows_count = scalar(flows_row)

    {producer_count, overlap_count} =
      if empty_pass?(result, matches_by_rank) do
        producer = scalar(one_row(query, Correlation.producer_rows_probe_sql()))

        overlap =
          if positive?(producer) and positive?(flows_count) do
            scalar(one_row(query, Correlation.topology_overlap_probe_sql()))
          else
            :skipped
          end

        {producer, overlap}
      else
        {:skipped, :skipped}
      end

    metrics =
      metrics_from(flows_row, fn [count] -> [{"flow_attribution_flows_read", count, %{}}] end) ++
        metrics_from(observations_row, fn [lag, recent] ->
          lag_metric =
            if lag, do: [{"flow_attribution_observation_lag_seconds", lag, %{}}], else: []

          lag_metric ++
            [
              {"flow_attribution_observation_ingest_rate",
               number(recent) / @ingest_window_seconds, %{}}
            ]
        end) ++
        metrics_from(partitions_row, fn [count] ->
          [{"flow_attribution_live_partitions", count, %{}}]
        end)

    {metrics, %{flows: flows_count, producer: producer_count, overlap: overlap_count}}
  end

  defp empty_pass?({:ok, 0}, matches) when is_map(matches) and map_size(matches) == 0, do: true
  defp empty_pass?(_result, _matches), do: false

  defp positive?(value) when is_integer(value) and value > 0, do: true
  defp positive?(_value), do: false

  defp one_row(query, sql) do
    case query.(sql) do
      {:ok, %{rows: [row]}} -> Enum.map(row, &number_or_nil/1)
      _ -> nil
    end
  end

  defp metrics_from(nil, _to_metrics), do: []
  defp metrics_from(row, to_metrics), do: to_metrics.(row)

  defp scalar([value | _]) do
    case number_or_nil(value) do
      count when is_integer(count) -> count
      count when is_float(count) -> trunc(count)
      _ -> nil
    end
  end

  defp scalar(_row), do: nil

  defp batch(metrics, now) do
    observed_at = DateTime.to_unix(now, :nanosecond)

    %MetricBatch{
      schema_version: "serviceradar.metric.v1",
      resource: %MetricResource{service_name: "core", service_type: "flow_attribution"},
      ingest_identity: %IngestIdentity{
        source: "flow-attribution-correlator",
        payload_kind: "metrics",
        producer_kind: "core"
      },
      emitted_at_unix_nano: observed_at,
      metrics:
        Enum.map(metrics, fn {name, value, tags} ->
          %Metric{
            name: name,
            kind: :METRIC_KIND_GAUGE,
            tags: Enum.map(tags, fn {k, v} -> %StringMapEntry{key: k, value: v} end),
            points: [%MetricPoint{value: number(value) * 1.0, observed_at_unix_nano: observed_at}]
          }
        end)
    }
  end

  defp number_or_nil(nil), do: nil
  defp number_or_nil(value), do: number(value)

  defp number(value) when is_integer(value) or is_float(value), do: value
  defp number(%Decimal{} = value), do: Decimal.to_float(value)

  defp number(value) when is_binary(value) do
    case Float.parse(value) do
      {number, _rest} -> number
      :error -> 0
    end
  end

  defp number(_value), do: 0
end
