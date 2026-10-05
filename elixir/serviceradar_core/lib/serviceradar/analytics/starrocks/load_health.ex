defmodule ServiceRadar.Analytics.StarRocks.LoadHealth do
  @moduledoc """
  Warehouse failure counters, published as delta sums through JetStream.

  Publishing is best effort with a bounded PubAck wait. Failures loading these
  health samples themselves never publish more samples, preventing an outage
  from feeding an unbounded metrics loop. Logs and local telemetry still emit.
  """

  alias ServiceRadar.NATS.JetStreamPublish
  alias Serviceradar.Metric.V1.IngestIdentity
  alias Serviceradar.Metric.V1.Metric
  alias Serviceradar.Metric.V1.MetricBatch
  alias Serviceradar.Metric.V1.MetricPoint
  alias Serviceradar.Metric.V1.MetricResource
  alias Serviceradar.Metric.V1.StringMapEntry

  require Logger

  @failure "event_writer_warehouse_load_failures"
  @partial "event_writer_warehouse_partial_writes"
  @subject "metrics.event_writer.warehouse"

  @doc "Publishes a failed attempt; options are passed to JetStreamPublish."
  def report(dataset, rows, cnpg_completed?, opts \\ []) do
    if health_only?(dataset, rows) do
      :ok
    else
      now = DateTime.to_unix(DateTime.utc_now(), :nanosecond)
      names = if cnpg_completed?, do: [@failure, @partial], else: [@failure]

      body = MetricBatch.encode(%MetricBatch{
        schema_version: "serviceradar.metric.v1",
        emitted_at_unix_nano: now,
        resource: %MetricResource{gateway_id: "core:#{node()}", service_name: "core", service_type: "event_writer"},
        ingest_identity: %IngestIdentity{source: "event-writer-warehouse", producer_kind: "core", payload_kind: "metrics"},
        metrics: Enum.map(names, fn name ->
          %Metric{
            name: name,
            kind: :METRIC_KIND_SUM,
            temporality: :METRIC_TEMPORALITY_DELTA,
            is_monotonic: true,
            tags: [%StringMapEntry{key: "dataset", value: to_string(dataset)}],
            points: [%MetricPoint{value: 1.0, observed_at_unix_nano: now}]
          }
        end)
      })

      case JetStreamPublish.publish(@subject, body, Keyword.put_new(opts, :timeout, 500)) do
        :ok -> :ok
        {:error, reason} = error ->
          Logger.warning("Warehouse failure metric publish failed", dataset: dataset, reason: inspect(reason))
          error
      end
    end
  rescue
    _error ->
      Logger.warning("Warehouse failure metric publisher raised", dataset: dataset)
      {:error, :health_publish_failed}
  catch
    :exit, _reason ->
      Logger.warning("Warehouse failure metric publisher exited", dataset: dataset)
      {:error, :health_publish_failed}
  end

  defp health_only?(dataset, rows) when dataset in [:metrics, "timeseries_metrics"] do
    Enum.all?(rows, fn row ->
      (Map.get(row, :metric_name) || Map.get(row, "metric_name")) in [@failure, @partial]
    end)
  end

  defp health_only?(_dataset, _rows), do: false
end
