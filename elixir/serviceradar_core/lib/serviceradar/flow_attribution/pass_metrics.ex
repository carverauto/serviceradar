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

  The warehouse readings come from three small queries; one that fails is left
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

    body =
      result
      |> metrics(duration_ms, matches_by_rank, readings(query))
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

  defp metrics(result, duration_ms, matches_by_rank, readings) do
    outcome = if match?({:ok, _}, result), do: "ok", else: "error"

    matches =
      matches_by_rank
      |> Enum.group_by(fn {rank, _count} -> Map.get(@strategies, rank, "other") end)
      |> Enum.map(fn {strategy, counts} ->
        {"flow_attribution_matches", Enum.sum(Enum.map(counts, &elem(&1, 1))),
         %{"strategy" => strategy}}
      end)

    stamped =
      case result do
        {:ok, count} when is_integer(count) -> [{"flow_attribution_stamped", count, %{}}]
        _ -> []
      end

    [{"flow_attribution_pass_duration_ms", duration_ms, %{"outcome" => outcome}}] ++
      matches ++ stamped ++ readings
  end

  defp readings(query) do
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

    reading(query, flows_read, fn [count] -> [{"flow_attribution_flows_read", count, %{}}] end) ++
      reading(query, observations, fn [lag, recent] ->
        lag_metric =
          if lag, do: [{"flow_attribution_observation_lag_seconds", lag, %{}}], else: []

        lag_metric ++
          [
            {"flow_attribution_observation_ingest_rate", number(recent) / @ingest_window_seconds,
             %{}}
          ]
      end) ++
      reading(query, partitions, fn [count] ->
        [{"flow_attribution_live_partitions", count, %{}}]
      end)
  end

  defp reading(query, sql, to_metrics) do
    case query.(sql) do
      {:ok, %{rows: [row]}} -> to_metrics.(Enum.map(row, &number_or_nil/1))
      _ -> []
    end
  end

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
