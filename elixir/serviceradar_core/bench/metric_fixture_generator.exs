defmodule ServiceRadar.Bench.MetricFixtureGenerator do
  @moduledoc """
  Builds a deterministic `MetricBatch` corpus for the metric benches.

  ## Why generated rather than committed

  The benches default to `tmp/metric-fixtures/demo-smoke-cli`, a capture taken from a live demo
  during the EventWriter backpressure work and never committed -- `tmp/` is gitignored. So the
  two metric benches could only ever run on the machine that produced that capture, which is why
  nothing has run them since.

  Committing synthetic payloads under that name would be worse than the gap it closes: they
  would read as a real capture and nobody would know the shapes were invented. This generates
  them instead, in code you can read, and the benches still accept the real capture through
  `METRIC_FIXTURE_PROFILE_DIR` when someone has one.

  ## What it is and is not

  It is REPRESENTATIVE OF SHAPE, not of a deployment: a fixed batch count, metric count and
  point count per batch, with values that vary but do not model any real workload's
  distribution. That is enough for the profile bench, which measures decode cost per byte and
  per point, and it is NOT enough to draw a capacity conclusion from. Deterministic on purpose,
  so two runs of the bench differ because the CODE changed rather than because the corpus did.
  """

  alias Serviceradar.Metric.V1.IngestIdentity
  alias Serviceradar.Metric.V1.Metric
  alias Serviceradar.Metric.V1.MetricBatch
  alias Serviceradar.Metric.V1.MetricPoint
  alias Serviceradar.Metric.V1.MetricResource

  @batches 8
  @metrics_per_batch 12
  @points_per_metric 6

  # A fixed instant rather than System.system_time/0: a corpus whose bytes change every run
  # would make the bench's byte totals move for reasons that have nothing to do with the code.
  @base_unix_nano 1_780_000_000_000_000_000

  @doc """
  Writes the corpus into `dir` and returns the paths, sorted the way the bench reads them.
  """
  def write!(dir) do
    File.mkdir_p!(dir)

    for index <- 1..@batches do
      path = Path.join(dir, "metric-batch-#{String.pad_leading(to_string(index), 3, "0")}.bin")
      File.write!(path, MetricBatch.encode(batch(index)))
      path
    end
  end

  def batch(index) do
    %MetricBatch{
      schema_version: "v1",
      resource: %MetricResource{
        agent_id: "bench-agent-#{index}",
        gateway_id: "bench-gateway",
        partition: "bench",
        service_name: "serviceradar-bench",
        service_type: "sysmon",
        host_id: "bench-host-#{index}",
        host_ip: "10.0.#{rem(index, 250)}.10"
      },
      ingest_identity: %IngestIdentity{
        source: "bench",
        payload_kind: "metric_batch",
        producer_id: "bench-producer-#{index}",
        producer_kind: "agent"
      },
      ingress_id: "bench-ingress-#{index}",
      ingress_timestamp_unix_nano: @base_unix_nano + index * 1_000_000,
      emitted_at_unix_nano: @base_unix_nano + index * 1_000_000 - 500_000,
      metrics: Enum.map(1..@metrics_per_batch, &metric(index, &1))
    }
  end

  defp metric(batch_index, metric_index) do
    %Metric{
      name: "bench.metric.#{metric_index}",
      metric_type: "gauge",
      unit: "By",
      scale: 1.0,
      points: Enum.map(1..@points_per_metric, &point(batch_index, metric_index, &1))
    }
  end

  defp point(batch_index, metric_index, point_index) do
    %MetricPoint{
      # Varies across every axis so no two points encode identically -- a corpus of repeated
      # values would compress and decode unrepresentatively.
      value: batch_index * 1000.0 + metric_index * 10.0 + point_index,
      observed_at_unix_nano: @base_unix_nano + point_index * 250_000_000,
      if_index: metric_index,
      interface_uid: "bench-if-#{batch_index}-#{metric_index}"
    }
  end
end
