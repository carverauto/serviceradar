defmodule ServiceRadar.Observability.MetricEnvelope do
  @moduledoc """
  Decoder for ServiceRadar's canonical non-OTLP metric protobuf envelope.

  OTLP metrics stay on the existing OTLP protobuf path. This envelope is for
  ServiceRadar-native scalar metric sources such as sysmon, SNMP, and plugins.
  """

  alias Serviceradar.Metric.V1.MetricBatch
  alias ServiceRadar.Observability.SeriesHintDrift
  alias ServiceRadar.Observability.TimeseriesSeriesKey

  @schema_version "serviceradar.metric.v1"

  @typedoc """
  Resolves the canonical device_id for rows whose gateway-attested
  `resource.device_id` is absent. Invoked at most once per decoded message
  (batched) on the persistence/row-build path only — never on the anomaly
  sample-extract path. Receives the distinct non-nil `target_device_ip` values
  from the message and must return a `%{ip => device_id}` map. See the
  `:device_resolver` option on `decode_rows_count/2`.
  """
  @type device_resolver :: ([String.t()] -> %{optional(String.t()) => String.t()})

  @spec decode_rows(binary(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def decode_rows(data, opts \\ []) when is_binary(data) do
    case decode_rows_count(data, opts) do
      {:ok, rows, _count} -> {:ok, rows}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Decode a metric envelope into timeseries rows plus the point count.

  ## Options

  - `:device_resolver` - optional `t:device_resolver/0` used on the
    persistence/row-build path to backfill the canonical `device_id` for rows
    that lack a gateway-attested `resource.device_id`. The resolver is called at
    most once per message (batched over the distinct target IPs). When omitted,
    decoding stays lookup-free and `device_id` is taken solely from the
    gateway-attested resource (current behavior).
  """
  @spec decode_rows_count(binary(), keyword()) ::
          {:ok, [map()], non_neg_integer()} | {:error, term()}
  def decode_rows_count(data, opts \\ []) when is_binary(data) do
    with {:ok, %MetricBatch{} = batch} <- decode_batch(data),
         true <- metric_batch?(batch) do
      {rows, count} = rows(batch)
      {:ok, resolve_device_ids(rows, Keyword.get(opts, :device_resolver)), count}
    else
      false -> {:error, :not_metric_envelope}
      {:error, reason} -> {:error, reason}
    end
  end

  # device_id is NULL for sysmon/SNMP/ICMP because no producer/gateway/core sets
  # resource.device_id. Resolve it here on the row-build path only, batched once
  # per message via an injected resolver keyed on target_device_ip. This stays
  # off the anomaly sample-extract path (which keys on attested identity, not
  # canonical device_id) and is a no-op unless a resolver is supplied.
  #
  # TODO(review): wire the resolver from the persistence caller
  # (ServiceRadar.EventWriter.Processors.Metrics.parse_message/1, not in this
  # file) using the same batched IP lookup the deleted ingestors used:
  #
  #   ips
  #   |> ServiceRadar.Identity.DeviceLookup.batch_lookup_by_ip(
  #        actor: actor, include_deleted: true, use_cache: false)
  #   |> Map.new(fn {ip, %{canonical_device_id: id}} -> {ip, id} end)
  #
  # passed as `device_resolver: fn ips -> ... end`. The caller must supply the
  # actor/partition context the pure decoder does not have. Reported partial.
  defp resolve_device_ids(rows, nil), do: rows

  defp resolve_device_ids(rows, resolver) when is_function(resolver, 1) do
    ips =
      rows
      |> Enum.filter(&is_nil(&1.device_id))
      |> Enum.map(& &1.target_device_ip)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    if ips == [] do
      rows
    else
      device_map = resolver.(ips)

      Enum.map(rows, fn row ->
        with nil <- row.device_id,
             device_id when is_binary(device_id) and device_id != "" <-
               Map.get(device_map, row.target_device_ip) do
          %{row | device_id: device_id}
        else
          _ -> row
        end
      end)
    end
  end

  defp resolve_device_ids(rows, _resolver), do: rows

  @spec metric_envelope?(binary()) :: boolean()
  def metric_envelope?(data) when is_binary(data) do
    case decode_rows(data) do
      {:ok, _rows} -> true
      {:error, _reason} -> false
    end
  end

  defp decode_batch(data) do
    {:ok, MetricBatch.decode(data)}
  rescue
    error -> {:error, error}
  end

  defp metric_batch?(%MetricBatch{schema_version: @schema_version, metrics: metrics})
       when is_list(metrics), do: true

  defp metric_batch?(_batch), do: false

  defp rows(%MetricBatch{} = batch) do
    resource = batch.resource || %{}
    ingest_identity = batch.ingest_identity || %{}
    created_at = DateTime.utc_now()

    {rows, count} =
      batch.metrics
      |> list_or_empty()
      |> Enum.reduce({[], 0}, fn metric, {rows, count} ->
        context = metric_context(batch, resource, ingest_identity, metric, created_at)

        metric.points
        |> list_or_empty()
        |> Enum.reduce({rows, count}, fn point, {rows, count} ->
          {[row(context, point) | rows], count + 1}
        end)
      end)

    {Enum.reverse(rows), count}
  end

  defp metric_context(batch, resource, ingest_identity, metric, created_at) do
    metric_tags =
      metric.tags
      |> entries_to_map()
      |> maybe_put("source", non_empty(ingest_identity.source))
      |> maybe_put("payload_kind", non_empty(ingest_identity.payload_kind))
      |> maybe_put("producer_id", non_empty(ingest_identity.producer_id))
      |> maybe_put("producer_kind", non_empty(ingest_identity.producer_kind))

    metric_metadata =
      metric.metadata
      |> entries_to_map()
      |> maybe_put("schema", batch.schema_version)
      |> maybe_put("kind", kind(metric.kind))
      |> maybe_put("temporality", temporality(metric.temporality))
      |> maybe_put("is_monotonic", metric.is_monotonic)
      |> maybe_put("counter_width", positive_int(metric.counter_width))
      |> maybe_put("ingress_id", non_empty(batch.ingress_id))
      |> maybe_put("ingress_timestamp_unix_nano", positive_int(batch.ingress_timestamp_unix_nano))

    %{
      created_at: created_at,
      metric: metric,
      metric_metadata: metric_metadata,
      metric_tags: metric_tags,
      resource: resource
    }
  end

  defp row(
         %{
           created_at: created_at,
           metric: metric,
           metric_metadata: metric_metadata,
           metric_tags: metric_tags,
           resource: resource
         },
         point
       ) do
    tags =
      metric_tags
      |> merge_entries(point.attributes)
      |> maybe_put("interface_uid", non_empty(point.interface_uid))

    metadata =
      metric_metadata
      |> merge_entries(point.metadata)
      |> maybe_put("raw_value", non_empty(point.raw_value))
      |> maybe_put("raw_value_type", raw_value_type(point.raw_value_type))
      |> maybe_put("start_time_unix_nano", positive_int(point.start_time_unix_nano))
      |> maybe_put("reset_anchor", non_empty(point.reset_anchor))

    base = %{
      timestamp: unix_nano_to_datetime(point.observed_at_unix_nano),
      gateway_id: non_empty(resource.gateway_id) || "unknown",
      agent_id: non_empty(resource.agent_id),
      metric_name: non_empty(metric.name) || "unknown",
      metric_type: non_empty(metric.metric_type) || metric_type(metric),
      device_id: non_empty(resource.device_id),
      value: point.value,
      unit: non_empty(metric.unit),
      tags: tags,
      partition: non_empty(resource.partition),
      scale: scale(metric.scale),
      is_delta: metric.temporality == :METRIC_TEMPORALITY_DELTA,
      # Persist the SNMP counter bit-width (32/64) as a first-class column so the SRQL
      # rate query can pick the correct wrap modulus. nil (unknown) -> NULL, which the
      # rate CTE handles with a 32-bit heuristic. Mirrors `is_delta` threading.
      counter_width: positive_int(metric.counter_width),
      target_device_ip: target_device_ip(resource, tags, metadata),
      if_index: positive_int(point.if_index),
      metadata: metadata,
      created_at: created_at
    }

    # Derive the canonical series key ONLY from the gateway-attested typed
    # fields. point.series_identity_hint is producer-set (proto field 9) and
    # never attested, so it must never become the canonical key. Keep the hint
    # as debug-only metadata and log when it disagrees with the derived key so
    # producer drift is observable without trusting the hint.
    series_key = TimeseriesSeriesKey.build(base)
    metadata = maybe_record_series_hint(metadata, point.series_identity_hint, series_key)

    base
    |> Map.put(:metadata, metadata)
    |> Map.put(:series_key, series_key)
  end

  defp maybe_record_series_hint(metadata, hint, series_key) do
    case non_empty(hint) do
      nil ->
        metadata

      hint when hint != series_key ->
        SeriesHintDrift.record(:metric_envelope, hint, series_key)
        Map.put_new(metadata, "series_identity_hint", hint)

      hint ->
        Map.put_new(metadata, "series_identity_hint", hint)
    end
  end

  defp unix_nano_to_datetime(value) when is_integer(value) and value > 0 do
    case DateTime.from_unix(value, :nanosecond) do
      {:ok, datetime} -> datetime
      _ -> DateTime.utc_now()
    end
  end

  defp unix_nano_to_datetime(_value), do: DateTime.utc_now()

  defp list_or_empty(value) when is_list(value), do: value
  defp list_or_empty(_value), do: []

  defp entries_to_map([]), do: %{}

  defp entries_to_map(entries) when is_list(entries) do
    Map.new(entries, fn entry -> {entry.key, entry.value} end)
  end

  defp entries_to_map(_entries), do: %{}

  defp merge_entries(map, []), do: map

  defp merge_entries(map, entries) when is_list(entries) do
    Map.merge(map, entries_to_map(entries))
  end

  defp merge_entries(map, _entries), do: map

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, _key, 0), do: map
  defp maybe_put(map, key, value), do: Map.put_new(map, key, value)

  defp non_empty(value) when is_binary(value) and value != "", do: value
  defp non_empty(_value), do: nil

  defp target_device_ip(resource, tags, metadata) do
    # Prefer IP-bearing keys before the logical target name. The producer sets
    # tags["host"] to the polled IP and tags["target"] to the logical name, so
    # tags["target"] must be the LAST fallback or it shadows the real IP.
    non_empty(resource.target_device_ip) ||
      non_empty(resource.host_ip) ||
      non_empty(Map.get(tags, "host")) ||
      non_empty(Map.get(metadata, "target_device_ip")) ||
      non_empty(Map.get(tags, "target"))
  end

  defp positive_int(value) when is_integer(value) and value > 0, do: value
  defp positive_int(_value), do: nil

  defp scale(value) when is_number(value) and value != 0, do: value
  defp scale(_value), do: nil

  defp metric_type(%{metric_type: metric_type}) when metric_type not in [nil, ""], do: metric_type
  defp metric_type(%{kind: :METRIC_KIND_SUM}), do: "sum"
  defp metric_type(%{kind: :METRIC_KIND_HISTOGRAM}), do: "histogram"
  defp metric_type(_metric), do: "gauge"

  defp kind(:METRIC_KIND_GAUGE), do: "gauge"
  defp kind(:METRIC_KIND_SUM), do: "sum"
  defp kind(:METRIC_KIND_HISTOGRAM), do: "histogram"
  defp kind(_kind), do: nil

  defp temporality(:METRIC_TEMPORALITY_DELTA), do: "delta"
  defp temporality(:METRIC_TEMPORALITY_CUMULATIVE), do: "cumulative"
  defp temporality(_temporality), do: nil

  defp raw_value_type(:METRIC_VALUE_TYPE_DOUBLE), do: "double"
  defp raw_value_type(:METRIC_VALUE_TYPE_INT64), do: "int64"
  defp raw_value_type(:METRIC_VALUE_TYPE_UINT64), do: "uint64"
  defp raw_value_type(:METRIC_VALUE_TYPE_BOOL), do: "bool"
  defp raw_value_type(:METRIC_VALUE_TYPE_STRING), do: "string"
  defp raw_value_type(_type), do: nil
end
