defmodule ServiceRadar.Edge.SweepHostMetrics do
  @moduledoc """
  Derives the per-host sweep gauges of a leased sweep batch and publishes them on the
  metrics stream.

  An unleased sweep's agent appends a `MetricBatch` with its per-host gauges
  (`sweep.host.*`) to each results chunk. A leased execution emits only its
  `SweepObservationBatchV1` and no metric batch: its lease carries one production
  capability, for `serviceradar.sweep.observation` (`move-agent-telemetry-to-edge-records`,
  Decision 3). Core owns those gauges instead and derives them here from each projected
  batch, so an agent whose sweep is leased produces the same per-host availability
  telemetry as one whose sweep is not (`fix-device-availability-timeline`, Decision 1).

  `ServiceRadar.Edge.SweepHostGauges` owns when they are published: after the ledger
  transaction that projected the batch commits, for a fresh primary delivery only, and again
  from its pending marker if that publish never completed. A replay, a late-fenced delivery
  or a refused projection therefore derives nothing.

  The series, units, tags and identity are the ones the agent's unleased batch carries
  once core attests it (`ServiceRadar.Edge.MetricsBatchProjection`), and a host counts as
  available under the rule the projection stores (`SweepProjection.host_available?/1`).
  The gauges are split in host order into messages of at most `max_points/0` points, and
  message `n` carries the `Nats-Msg-Id` `<event_id>:sweep-host-metrics:<n>`. A republish
  of the same batch builds the same messages and points, so JetStream deduplicates it within
  its window and the metrics store, keyed by `(timestamp, gateway_id, series_key)`, keeps one
  row per point after it. Each message goes through `ServiceRadar.NATS.DurablePublish`, which falls
  back to a durable retry job when the publish fails.
  """

  alias ServiceRadar.Edge.MetricsBatchProjection
  alias ServiceRadar.Edge.SweepProjection
  alias Serviceradar.Edge.V1.SweepHostObservationV1
  alias Serviceradar.Edge.V1.SweepObservationBatchV1
  alias Serviceradar.Metric.V1.IngestIdentity
  alias Serviceradar.Metric.V1.Metric
  alias Serviceradar.Metric.V1.MetricBatch
  alias Serviceradar.Metric.V1.MetricPoint
  alias Serviceradar.Metric.V1.MetricResource
  alias Serviceradar.Metric.V1.StringMapEntry
  alias ServiceRadar.NATS.DurablePublish

  require Logger

  @schema "serviceradar.metric.v1"
  @family "sweep"
  @max_points 1_000

  # The tests may replace DurablePublish's publish, transaction check and retry insert.
  @publish_opts [:publish, :in_transaction?, :enqueue]

  @type identity :: %{
          required(:agent_id) => String.t(),
          required(:gateway_id) => String.t() | nil,
          required(:partition) => String.t() | nil,
          required(:event_id) => String.t()
        }

  @doc "The most points one published message carries."
  @spec max_points() :: pos_integer()
  def max_points, do: @max_points

  @doc """
  Derives and publishes the gauges of `batch`, attributed to `identity`. Returns `:ok` once
  every message is stored in JetStream or queued as a durable retry job, and
  `{:error, reason}` when one could be neither; the caller keeps its pending marker then
  (`ServiceRadar.Edge.SweepHostGauges`).
  """
  @spec publish(SweepObservationBatchV1.t(), identity(), keyword()) :: :ok | {:error, term()}
  def publish(%SweepObservationBatchV1{} = batch, identity, opts \\ []) do
    publish_opts = Keyword.take(opts, @publish_opts)

    batch
    |> build(identity)
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {metric_batch, index}, :ok ->
      msg_id = "#{identity.event_id}:sweep-host-metrics:#{index}"

      case DurablePublish.publish(
             MetricsBatchProjection.subject(@family, metric_batch),
             MetricBatch.encode(metric_batch),
             [msg_id: msg_id] ++ publish_opts
           ) do
        :ok ->
          {:cont, :ok}

        {:ok, :enqueued} ->
          {:cont, :ok}

        {:error, reason} ->
          Logger.warning("Leased sweep host gauges were not published; the marker stays",
            msg_id: msg_id,
            reason: inspect(reason)
          )

          {:halt, {:error, reason}}
      end
    end)
  end

  @doc """
  The metric batches of `batch`'s per-host gauges, attributed to `identity`, at most
  `max_points/0` points each, in host order. A batch with no hosts has none.
  """
  @spec build(SweepObservationBatchV1.t(), identity()) :: [MetricBatch.t()]
  def build(%SweepObservationBatchV1{} = batch, identity) do
    base_tags = %{
      "execution_id" => Ecto.UUID.load!(batch.execution_id),
      "sweep_group_id" => Ecto.UUID.load!(batch.sweep_group_id)
    }

    checks = List.to_tuple(batch.tested_checks)

    tcp_ports =
      for check <- batch.tested_checks, check.protocol == :TRANSPORT_PROTOCOL_TCP, do: check.port

    batch.hosts
    |> Enum.flat_map(&host_points(&1, batch.observed_at_unix_nano, base_tags, checks, tcp_ports))
    |> Enum.chunk_every(@max_points)
    |> Enum.map(&metric_batch(&1, identity))
  end

  defp host_points(%SweepHostObservationV1{} = host, batch_at, base_tags, checks, tcp_ports) do
    observed_at = batch_at + host.observed_at_delta_nano
    tags = base_tags |> Map.put("target", SweepProjection.host_address(host)) |> hostname(host)

    [
      {"sweep.host.available", "1",
       bool_point(SweepProjection.host_available?(host), observed_at, tags)}
    ] ++
      icmp_points(host.icmp, observed_at, tags) ++
      port_points(host, checks, tcp_ports, observed_at, tags)
  end

  defp hostname(tags, %SweepHostObservationV1{hostname: name})
       when is_binary(name) and name != "",
       do: Map.put(tags, "hostname", name)

  defp hostname(tags, _host), do: tags

  defp icmp_points(nil, _observed_at, _tags), do: []

  defp icmp_points(icmp, observed_at, tags) do
    [{"sweep.host.icmp_available", "1", bool_point(icmp.target_reached, observed_at, tags)}] ++
      optional_point(
        "sweep.host.icmp_response_time_ns",
        "ns",
        icmp.round_trip_micro && icmp.round_trip_micro * 1_000,
        observed_at,
        tags
      ) ++
      optional_point("sweep.host.icmp_packet_loss", "1", icmp.packet_loss_pct, observed_at, tags)
  end

  defp port_points(%SweepHostObservationV1{tcp: nil}, _checks, _tcp_ports, _observed_at, _tags),
    do: []

  defp port_points(host, checks, tcp_ports, observed_at, tags) do
    open =
      Map.new(host.open_ports, fn open_port ->
        {elem(checks, open_port.tested_check_index).port, open_port}
      end)

    Enum.flat_map(tcp_ports, fn port ->
      port_tags = Map.put(tags, "port", Integer.to_string(port))

      case Map.get(open, port) do
        nil ->
          [{"sweep.host.port.available", "1", bool_point(false, observed_at, port_tags)}]

        open_port ->
          port_tags = service(port_tags, open_port.service)

          [{"sweep.host.port.available", "1", bool_point(true, observed_at, port_tags)}] ++
            optional_point(
              "sweep.host.port.response_time_ns",
              "ns",
              open_port.response_time_nano,
              observed_at,
              port_tags
            )
      end
    end)
  end

  defp service(tags, name) when is_binary(name) and name != "", do: Map.put(tags, "service", name)
  defp service(tags, _name), do: tags

  defp optional_point(_name, _unit, nil, _observed_at, _tags), do: []

  defp optional_point(name, unit, value, observed_at, tags),
    do: [{name, unit, gauge_point(value, observed_at, tags)}]

  defp bool_point(value, observed_at, tags) do
    %MetricPoint{
      value: if(value, do: 1.0, else: 0.0),
      raw_value: if(value, do: "true", else: "false"),
      raw_value_type: :METRIC_VALUE_TYPE_BOOL,
      observed_at_unix_nano: observed_at,
      attributes: entries(tags)
    }
  end

  defp gauge_point(value, observed_at, tags) do
    value = value / 1

    %MetricPoint{
      value: value,
      raw_value: raw_number(value),
      raw_value_type: :METRIC_VALUE_TYPE_DOUBLE,
      observed_at_unix_nano: observed_at,
      attributes: entries(tags)
    }
  end

  # The agent formats a gauge's raw value as the shortest decimal without an exponent.
  defp raw_number(value) when value == trunc(value), do: Integer.to_string(trunc(value))
  defp raw_number(value), do: :erlang.float_to_binary(value, [:short])

  defp metric_batch(points, identity) do
    {names, metrics} =
      Enum.reduce(points, {[], %{}}, fn {name, unit, point}, {names, metrics} ->
        case Map.fetch(metrics, name) do
          {:ok, metric} ->
            {names, Map.put(metrics, name, %{metric | points: [point | metric.points]})}

          :error ->
            {[name | names], Map.put(metrics, name, %{metric(name, unit) | points: [point]})}
        end
      end)

    %MetricBatch{
      schema_version: @schema,
      resource: %MetricResource{
        agent_id: identity.agent_id,
        gateway_id: identity.gateway_id || "",
        partition: identity.partition || "",
        service_name: "network_sweep",
        service_type: "sweep"
      },
      ingest_identity: %IngestIdentity{
        source: "sweep-metrics",
        payload_kind: @schema,
        producer_id: identity.agent_id,
        producer_kind: "sweep"
      },
      ingress_id: identity.event_id,
      ingress_timestamp_unix_nano: System.system_time(:nanosecond),
      emitted_at_unix_nano: System.system_time(:nanosecond),
      metrics:
        names
        |> Enum.reverse()
        |> Enum.map(fn name ->
          metric = Map.fetch!(metrics, name)
          %{metric | points: Enum.reverse(metric.points)}
        end)
    }
  end

  defp metric(name, unit) do
    %Metric{
      name: name,
      metric_type: "sweep",
      kind: :METRIC_KIND_GAUGE,
      temporality: :METRIC_TEMPORALITY_UNSPECIFIED,
      unit: unit,
      tags: entries(%{"metric_family" => "sweep"})
    }
  end

  defp entries(map) do
    map
    |> Enum.sort()
    |> Enum.map(fn {key, value} -> %StringMapEntry{key: key, value: value} end)
  end
end
