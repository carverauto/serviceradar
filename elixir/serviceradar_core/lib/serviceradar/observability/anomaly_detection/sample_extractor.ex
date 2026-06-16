defmodule ServiceRadar.Observability.AnomalyDetection.SampleExtractor do
  @moduledoc """
  Extracts scalar anomaly-analysis samples from telemetry stream messages.
  """

  alias ServiceRadar.EventWriter.Processors.Flows
  alias ServiceRadar.EventWriter.Processors.OtelMetrics
  alias Serviceradar.Metric.V1.MetricBatch
  alias ServiceRadar.Observability.SeriesHintDrift

  require Logger

  @schema_version "serviceradar.metric.v1"
  @max_unix_nano 18_446_744_073_709_551_615

  @type sample :: %{
          required(:series_key) => String.t(),
          required(:event_id) => String.t(),
          required(:order_key) => term(),
          required(:value) => number(),
          required(:observed_at_unix_nano) => non_neg_integer() | nil,
          required(:subject) => String.t(),
          required(:metric_class) => String.t(),
          optional(:metadata) => map()
        }

  @doc """
  Extracts zero or more scalar samples from a Broadway message.
  """
  @spec extract(map()) :: [sample()]
  def extract(%{metadata: metadata} = message) do
    subject = subject(metadata)
    ingress_metadata = ingress_metadata(message)

    cond do
      String.starts_with?(subject, "metrics.") ->
        extract_metrics(message, subject, ingress_metadata)

      String.starts_with?(subject, "otel.metrics") ->
        extract_otel_metrics(message, subject, ingress_metadata)

      subject in ["flows.raw.netflow", "flows.raw.sflow"] or
          String.starts_with?(subject, "flow.attributed.") ->
        extract_flow(message, subject, ingress_metadata)

      true ->
        []
    end
  end

  def extract(_message), do: []

  defp extract_metrics(%{data: data}, subject, ingress_metadata) when is_binary(data) do
    case decode_metric_batch(data) do
      {:ok, %MetricBatch{schema_version: @schema_version} = batch} ->
        metric_batch_samples(batch, subject, ingress_metadata)

      _ ->
        []
    end
  end

  defp extract_metrics(_message, _subject, _ingress_metadata), do: []

  defp decode_metric_batch(data) do
    {:ok, MetricBatch.decode(data)}
  rescue
    error -> {:error, error}
  end

  defp metric_batch_samples(%MetricBatch{} = batch, subject, ingress_metadata) do
    resource = batch.resource || %{}
    ingest_identity = batch.ingest_identity || %{}
    batch_ingress_metadata = batch_ingress_metadata(batch, ingress_metadata)

    {samples, telemetry} =
      batch.metrics
      |> list_or_empty()
      |> Enum.reduce({[], empty_extract_telemetry()}, fn metric, {samples, telemetry} ->
        context = metric_context(batch, resource, ingest_identity, metric, batch_ingress_metadata)

        metric.points
        |> list_or_empty()
        |> Enum.reduce({samples, telemetry}, fn point, {samples, telemetry} ->
          case metric_point_sample(context, point, subject) do
            {:drop, reason} ->
              {samples, record_extract_drop(telemetry, reason)}

            sample ->
              {[sample | samples], record_extract_accept(telemetry, context.metric_class)}
          end
        end)
      end)

    emit_extract_telemetry(subject, telemetry)

    Enum.reverse(samples)
  end

  defp metric_context(batch, resource, ingest_identity, metric, ingress_metadata) do
    metric_tags =
      metric.tags
      |> entries_to_map()
      |> maybe_put_metadata("source", non_empty(ingest_identity.source))
      |> maybe_put_metadata("payload_kind", non_empty(ingest_identity.payload_kind))
      |> maybe_put_metadata("producer_id", non_empty(ingest_identity.producer_id))
      |> maybe_put_metadata("producer_kind", non_empty(ingest_identity.producer_kind))

    metric_class = non_empty(metric.metric_type) || fallback_metric_type(metric)

    common_base =
      %{
        gateway_id: non_empty(resource.gateway_id) || "unknown",
        agent_id: non_empty(resource.agent_id),
        metric_name: non_empty(metric.name) || "unknown",
        metric_type: metric_class,
        device_id: non_empty(resource.device_id),
        host_id: non_empty(resource.host_id),
        host_ip: non_empty(resource.host_ip),
        unit: non_empty(metric.unit),
        partition: non_empty(resource.partition),
        scale: scale(metric.scale),
        is_delta: metric.temporality == :METRIC_TEMPORALITY_DELTA
      }
      |> maybe_put_metadata(:schema, batch.schema_version)
      |> maybe_put_metadata(:kind, metric_kind(metric.kind))
      |> maybe_put_metadata(:temporality, metric_temporality(metric.temporality))
      |> maybe_put_metadata(:is_monotonic, metric.is_monotonic)
      |> maybe_put_metadata(:counter_width, positive_int(metric.counter_width))

    %{
      common_base: common_base,
      ingress_metadata: ingress_metadata,
      metric_class: metric_class,
      metric_metadata: entries_to_map(metric.metadata),
      metric_tags: metric_tags,
      resource: resource
    }
  end

  defp metric_point_sample(
         %{
           common_base: common_base,
           ingress_metadata: ingress_metadata,
           metric_class: metric_class,
           metric_metadata: metric_metadata,
           metric_tags: metric_tags,
           resource: resource
         },
         point,
         subject
       ) do
    tags =
      metric_tags
      |> merge_entries(point.attributes)
      |> maybe_put_metadata("interface_uid", non_empty(point.interface_uid))

    nested_metadata = merge_entries(metric_metadata, point.metadata)

    cond do
      process_metric_sample?(metric_class, common_base.metric_name) ->
        {:drop, :process_metric}

      unidentified_sysmon_sample?(metric_class, resource, point) ->
        {:drop, :unidentified_sysmon}

      true ->
        timestamp = timestamp_nano(point.observed_at_unix_nano)

        base =
          common_base
          |> point_base(point, timestamp, tags, nested_metadata, resource)
          |> maybe_put_metadata(:raw_value, non_empty(point.raw_value))
          |> maybe_put_metadata(:raw_value_type, metric_value_type(point.raw_value_type))
          |> maybe_put_metadata(:start_time_unix_nano, positive_int(point.start_time_unix_nano))
          |> maybe_put_metadata(:reset_anchor, non_empty(point.reset_anchor))

        # Derive the anomaly series key from gateway-attested typed fields ONLY,
        # rendered HUMAN-READABLE so verdict titles and the event_live "Series"
        # field show meaning, not an md5. (The CNPG timeseries_metrics row path in
        # MetricEnvelope keeps the md5 TimeseriesSeriesKey.build/1 — dashboards
        # depend on that and it is intentionally left unchanged.)
        #
        # point.series_identity_hint is producer-set (proto field 9) and never
        # attested, so it must never become the canonical key. Keep the hint as
        # debug-only metadata and log a mismatch so producer drift is observable
        # without trusting the hint on the anomaly hot path.
        {identity, unstable?} = resource_series_identity(resource)
        readable_identity = readable_series_identity(metric_class, base, identity, tags, point)
        series_key = prefix_series_key(metric_class, readable_identity)

        nested_metadata =
          nested_metadata
          |> maybe_record_series_hint(point.series_identity_hint, series_key)
          |> maybe_tag_instability(unstable?)

        metadata = sample_metadata(nested_metadata, base, ingress_metadata)
        event_identity = typed_metric_event_identity(ingress_metadata, nested_metadata)
        order_timestamp = typed_metric_order_timestamp(timestamp, ingress_metadata)

        build_sample(
          series_key,
          point.value,
          timestamp,
          subject,
          metric_class,
          metadata,
          event_identity,
          order_timestamp
        )
    end
  end

  # Resource identity for the readable anomaly series key. Mirrors the
  # network-agnostic preference enforced by unidentified_sysmon_sample?/3:
  # prefer a STABLE attested id (host_id -> agent_id -> device_id) and only fall
  # back to host_ip when no stable id exists. A host_ip fallback is flagged
  # unstable so a DHCP lease change that re-keys the series is observable.
  defp resource_series_identity(resource) do
    cond do
      id = non_empty(resource.host_id) -> {id, false}
      id = non_empty(resource.agent_id) -> {id, false}
      id = non_empty(resource.device_id) -> {id, false}
      id = non_empty(resource.host_ip) -> {id, true}
      true -> {nil, false}
    end
  end

  # Build the human-readable, attested-derived series identity. The shape is
  #   "<class>:<family>:<resource-identity>[:<dimension>...]"
  # e.g. "sysmon:cpu:host-a:0", "sysmon:memory:agent-7", "snmp:10.0.0.20:7".
  # The distinguishing dimensions come ONLY from attested point fields
  # (core_id/mount_point attributes, if_index typed field, other attested tags),
  # never from point.series_identity_hint.
  defp readable_series_identity(metric_class, base, identity, tags, point) do
    {class_component, family} = class_and_family(metric_class, base.metric_name)

    [class_component, family, identity_component(identity, base)]
    |> Enum.reject(&is_nil/1)
    |> Kernel.++(series_dimensions(tags, point))
    |> Enum.join(":")
  end

  # The leading class component plus an optional metric family. For sysmon the
  # producer encodes the family in the metric_type ("sysmon.cpu") or, when only
  # the bare "sysmon" class is present, in the metric_name prefix
  # ("memory.used_percent"). For non-sysmon classes the class itself is the
  # readable prefix and there is no family segment.
  defp class_and_family(metric_class, metric_name) do
    case String.split(metric_class, ".", parts: 2) do
      ["sysmon", family] when family != "" ->
        {"sysmon", family}

      ["sysmon"] ->
        {"sysmon", metric_name_family(metric_name)}

      _ ->
        {metric_class, nil}
    end
  end

  defp metric_name_family(metric_name) when is_binary(metric_name) do
    case String.split(metric_name, ".", parts: 2) do
      [family, _rest] when family != "" -> family
      _ -> nil
    end
  end

  defp metric_name_family(_metric_name), do: nil

  # Resource identity falls back to the attested target IP (SNMP/ICMP polls
  # carry no host_id but do carry the polled device IP via target_device_ip) and
  # finally to "unknown" so a key is always well-formed. Sysmon samples that
  # reach this point already passed unidentified_sysmon_sample?/3, so they have a
  # real identity.
  defp identity_component(nil, base), do: non_empty(Map.get(base, :target_device_ip)) || "unknown"

  defp identity_component(identity, _base), do: identity

  # Distinguishing dimensions from attested point fields, in a stable order so
  # the readable key is deterministic. core_id/mount_point are the sysmon
  # per-core / per-mount dimensions; if_index is the SNMP interface dimension;
  # any remaining attested tag (e.g. an environment sensor) keeps otherwise
  # identical series distinct. Identity/source/volatile keys are excluded so
  # they never re-fork or pollute the dimension.
  # Keys that identify the resource, name the producer, or carry volatile noise
  # must never appear as a distinguishing dimension: identity keys would re-key
  # the series per network change, and source/producer keys are constant per
  # producer. Mirrors the volatile-tag exclusions in TimeseriesSeriesKey.
  @series_dimension_excluded_keys MapSet.new([
                                    "host_id",
                                    "agent_id",
                                    "device_id",
                                    "host_ip",
                                    "host",
                                    "target",
                                    "interface_uid",
                                    "source",
                                    "payload_kind",
                                    "producer_id",
                                    "producer_kind",
                                    "available",
                                    "metric",
                                    "packet_loss"
                                  ])

  defp series_dimensions(tags, point) do
    leading =
      ["core_id", "mount_point"]
      |> Enum.map(&non_empty(Map.get(tags, &1)))
      |> Enum.reject(&is_nil/1)

    if_index =
      case positive_int(point.if_index) do
        nil -> []
        value -> [Integer.to_string(value)]
      end

    used = ["core_id", "mount_point"]

    extra =
      tags
      |> Enum.reject(fn {key, value} ->
        key = to_string(key)

        key in used or MapSet.member?(@series_dimension_excluded_keys, key) or
          non_empty(value) == nil
      end)
      |> Enum.sort_by(&to_string(elem(&1, 0)))
      |> Enum.map(fn {_key, value} -> normalize_dimension(value) end)

    leading ++ if_index ++ extra
  end

  defp normalize_dimension(value) when is_binary(value), do: String.trim(value)
  defp normalize_dimension(value), do: to_string(value)

  # Prefix the readable identity with the metric class so verdicts read
  # "sysmon.cpu:sysmon:cpu:host-a:0", but skip the prefix when the identity
  # already starts with it (the bare "sysmon" class case where the readable
  # identity already begins "sysmon:...") to avoid a doubled "sysmon:sysmon:".
  defp prefix_series_key(metric_class, readable_identity) do
    if String.starts_with?(readable_identity, "#{metric_class}:") do
      readable_identity
    else
      "#{metric_class}:#{readable_identity}"
    end
  end

  # Record a host_ip-derived (unstable) identity so downstream consumers can
  # warn that a DHCP lease change may re-key the series. Stored as a string to
  # match the producer-emitted "host_identity_unstable" metadata.
  defp maybe_tag_instability(metadata, true),
    do: Map.put(metadata, "host_identity_unstable", "true")

  defp maybe_tag_instability(metadata, false), do: metadata

  # Optional schema-descriptor keys are stored on common_base only when present
  # (added there via maybe_put_metadata), so Map.take extracts exactly that
  # subset. Merging it once reproduces the old per-key maybe_put_metadata chain
  # without re-fetching/re-putting each value individually.
  @common_base_descriptor_keys [:schema, :kind, :temporality, :is_monotonic, :counter_width]

  defp point_base(common_base, point, timestamp, tags, nested_metadata, resource) do
    base = %{
      gateway_id: common_base.gateway_id,
      agent_id: common_base.agent_id,
      metric_name: common_base.metric_name,
      metric_type: common_base.metric_type,
      device_id: common_base.device_id,
      host_id: common_base.host_id,
      host_ip: common_base.host_ip,
      unit: common_base.unit,
      partition: common_base.partition,
      scale: common_base.scale,
      is_delta: common_base.is_delta,
      timestamp: timestamp,
      value: point.value,
      tags: tags,
      target_device_ip: target_device_ip(resource, tags, nested_metadata),
      if_index: positive_int(point.if_index),
      metadata: nested_metadata
    }

    Map.merge(base, Map.take(common_base, @common_base_descriptor_keys))
  end

  defp extract_otel_metrics(message, subject, ingress_metadata) do
    message
    |> OtelMetrics.parse_message()
    |> otel_samples(subject, ingress_metadata)
  end

  defp otel_samples(nil, _subject, _ingress_metadata), do: []

  defp otel_samples(rows, subject, ingress_metadata) when is_list(rows) do
    rows
    |> Enum.reduce([], fn row, samples ->
      case otel_sample(row, subject, ingress_metadata) do
        nil -> samples
        sample -> [sample | samples]
      end
    end)
    |> Enum.reverse()
  end

  defp extract_flow(message, subject, ingress_metadata) do
    case Flows.parse_message(message) do
      %{bytes_total: value} = row ->
        "flow:#{subject}:#{row[:sampler_address] || "unknown"}:#{row[:src_endpoint_ip]}:#{row[:dst_endpoint_ip]}:#{row[:protocol_num]}"
        |> build_sample(
          value,
          timestamp_nano(row[:time]),
          subject,
          "flow",
          merge_ingress_metadata(row, ingress_metadata)
        )
        |> List.wrap()

      _ ->
        []
    end
  end

  defp otel_sample(%{value: value} = row, subject, ingress_metadata) do
    build_sample(
      "otel:#{row[:service_name]}:#{row[:metric_name]}:#{row[:attributes_hash]}",
      value,
      timestamp_nano(row[:timestamp]),
      subject,
      "otel.metric_point",
      merge_ingress_metadata(row, ingress_metadata)
    )
  end

  defp otel_sample(%{duration_ms: value} = row, subject, ingress_metadata) do
    build_sample(
      "otel:span_duration:#{row[:service_name]}:#{row[:span_name]}:#{row[:span_id]}",
      value,
      timestamp_nano(row[:timestamp]),
      subject,
      "otel.span_duration",
      merge_ingress_metadata(row, ingress_metadata)
    )
  end

  defp otel_sample(_row, _subject, _ingress_metadata), do: nil

  defp build_sample(_series_key, value, _timestamp, _subject, _metric_class, _metadata)
       when not is_number(value), do: nil

  defp build_sample(series_key, value, timestamp, subject, metric_class, metadata) do
    sample_hash = sample_hash(series_key, timestamp, subject, value)
    event_identity = explicit_event_identity(metadata)
    order_timestamp = order_timestamp(timestamp, metadata)

    build_sample(
      series_key,
      value,
      timestamp,
      subject,
      metric_class,
      metadata,
      event_identity,
      order_timestamp,
      sample_hash
    )
  end

  defp build_sample(
         _series_key,
         value,
         _timestamp,
         _subject,
         _metric_class,
         _metadata,
         _event_identity,
         _order_timestamp
       )
       when not is_number(value), do: nil

  defp build_sample(
         series_key,
         value,
         timestamp,
         subject,
         metric_class,
         metadata,
         event_identity,
         order_timestamp
       ) do
    sample_hash = sample_hash(series_key, timestamp, subject, value)

    build_sample(
      series_key,
      value,
      timestamp,
      subject,
      metric_class,
      metadata,
      event_identity,
      order_timestamp,
      sample_hash
    )
  end

  defp build_sample(
         series_key,
         value,
         timestamp,
         subject,
         metric_class,
         metadata,
         event_identity,
         order_timestamp,
         sample_hash
       ) do
    %{
      series_key: series_key,
      event_id: event_id(event_identity, sample_hash),
      order_key: order_key(event_identity, order_timestamp, timestamp, sample_hash),
      value: value * 1.0,
      observed_at_unix_nano: timestamp,
      subject: subject,
      metric_class: metric_class,
      metadata: metadata
    }
  end

  defp timestamp_nano(%DateTime{} = datetime) do
    datetime
    |> DateTime.to_unix(:nanosecond)
    |> valid_unix_nano()
  end

  defp timestamp_nano(value) when is_integer(value), do: valid_unix_nano(value)

  defp timestamp_nano(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> timestamp_nano(datetime)
      _ -> nil
    end
  end

  defp timestamp_nano(_value), do: nil

  defp valid_unix_nano(value) when is_integer(value) and value >= 0 and value <= @max_unix_nano,
    do: value

  defp valid_unix_nano(_value), do: nil

  defp ingress_metadata(%{metadata: metadata}) do
    metadata
    |> metadata_headers()
    |> ingress_metadata_from_headers()
  end

  defp ingress_metadata_from_headers(headers) do
    %{}
    |> maybe_put_metadata("ingress_id", header_value(headers, "sr-ingress-id"))
    |> maybe_put_metadata(
      "ingress_timestamp_unix_nano",
      headers |> header_value("sr-ingress-time-unix-nano") |> parse_non_negative_integer()
    )
  end

  defp metadata_headers(metadata) when is_map(metadata), do: Map.get(metadata, :headers)
  defp metadata_headers(_metadata), do: nil

  defp batch_ingress_metadata(batch, ingress_metadata) do
    %{}
    |> maybe_put_metadata("ingress_id", non_empty(batch.ingress_id))
    |> maybe_put_metadata(
      "ingress_timestamp_unix_nano",
      positive_int(batch.ingress_timestamp_unix_nano)
    )
    |> Map.merge(ingress_metadata)
  end

  defp typed_metric_event_identity(%{"ingress_id" => ingress_id}, _metadata)
       when is_binary(ingress_id) and ingress_id != "", do: {:ingress_id, ingress_id}

  defp typed_metric_event_identity(_ingress_metadata, metadata),
    do: explicit_event_identity(metadata)

  defp typed_metric_order_timestamp(_timestamp, %{
         "ingress_timestamp_unix_nano" => ingress_timestamp
       })
       when is_integer(ingress_timestamp), do: ingress_timestamp

  defp typed_metric_order_timestamp(timestamp, _ingress_metadata), do: timestamp || 0

  defp sample_metadata(nested_metadata, base, ingress_metadata) do
    metadata =
      if map_size(nested_metadata) == 0 do
        base
      else
        Map.merge(nested_metadata, base)
      end

    if map_size(ingress_metadata) == 0 do
      metadata
    else
      Map.merge(metadata, ingress_metadata)
    end
  end

  defp list_or_empty(value) when is_list(value), do: value
  defp list_or_empty(_value), do: []

  defp entries_to_map([]), do: %{}

  defp entries_to_map(entries) when is_list(entries) do
    Map.new(entries, fn entry -> {entry.key, entry.value} end)
  end

  defp entries_to_map(_entries), do: %{}

  defp merge_entries(map, entries) when is_map(map) and is_list(entries) do
    case entries do
      [] -> map
      _ -> Map.merge(map, entries_to_map(entries))
    end
  end

  defp merge_entries(map, _entries) when is_map(map), do: map

  defp target_device_ip(resource, tags, metadata) do
    # Prefer IP-bearing keys before the logical target name. The producer sets
    # tags["host"] to the polled IP and tags["target"] to the logical name, so
    # tags["target"] must be the LAST fallback or it shadows the real IP.
    non_empty(resource.target_device_ip) ||
      non_empty(Map.get(tags, "host")) ||
      non_empty(Map.get(metadata, "target_device_ip")) ||
      non_empty(Map.get(tags, "target"))
  end

  # Admit/drop is based ONLY on gateway-attested resource identity. The
  # producer-set point.series_identity_hint (never attested) must not appear
  # here, or a spoofed hint could rescue an identity-less sample past the
  # anti-spoof guard. `point` is retained in the signature to keep callers
  # unchanged.
  defp unidentified_sysmon_sample?(metric_class, resource, _point) do
    String.starts_with?(metric_class, "sysmon.") and
      is_nil(non_empty(resource.agent_id)) and is_nil(non_empty(resource.device_id)) and
      is_nil(non_empty(resource.host_id)) and is_nil(non_empty(resource.host_ip))
  end

  # Process telemetry is diagnostic by default. Keep it on the JetStream/CNPG
  # path, but do not feed the real-time anomaly engine with high-cardinality
  # process rows unless a future explicit opt-in path is added.
  defp process_metric_sample?(metric_class, _metric_name)
       when is_binary(metric_class) and metric_class == "sysmon.process", do: true

  defp process_metric_sample?(metric_class, metric_name)
       when is_binary(metric_class) and is_binary(metric_name),
       do: metric_class == "sysmon" and String.starts_with?(metric_name, "process.")

  defp process_metric_sample?(_metric_class, _metric_name), do: false

  defp empty_extract_telemetry do
    %{
      accepted_samples: 0,
      dropped_process_samples: 0,
      dropped_unidentified_samples: 0,
      accepted_metric_classes: MapSet.new()
    }
  end

  defp record_extract_accept(telemetry, metric_class) do
    %{
      telemetry
      | accepted_samples: telemetry.accepted_samples + 1,
        accepted_metric_classes:
          if(is_binary(metric_class),
            do: MapSet.put(telemetry.accepted_metric_classes, metric_class),
            else: telemetry.accepted_metric_classes
          )
    }
  end

  defp record_extract_drop(telemetry, :process_metric) do
    %{telemetry | dropped_process_samples: telemetry.dropped_process_samples + 1}
  end

  defp record_extract_drop(telemetry, :unidentified_sysmon) do
    %{telemetry | dropped_unidentified_samples: telemetry.dropped_unidentified_samples + 1}
  end

  defp emit_extract_telemetry(subject, telemetry) do
    dropped_samples = telemetry.dropped_process_samples + telemetry.dropped_unidentified_samples

    :telemetry.execute(
      [:serviceradar, :observability, :anomaly_detection, :sample_extractor, :batch],
      %{
        accepted_samples: telemetry.accepted_samples,
        dropped_samples: dropped_samples,
        dropped_process_samples: telemetry.dropped_process_samples,
        dropped_unidentified_samples: telemetry.dropped_unidentified_samples,
        metric_class_count: MapSet.size(telemetry.accepted_metric_classes)
      },
      %{subject_class: subject_class(subject)}
    )

    :ok
  end

  defp subject_class(subject) when is_binary(subject) do
    cond do
      String.starts_with?(subject, "metrics.sysmon.") -> "metrics_sysmon"
      String.starts_with?(subject, "metrics.snmp.") -> "metrics_snmp"
      String.starts_with?(subject, "metrics.") -> "metrics"
      String.starts_with?(subject, "otel.metrics.") -> "otel_metrics"
      String.starts_with?(subject, "flows.") or String.starts_with?(subject, "flow.") -> "flows"
      true -> "other"
    end
  end

  # Keep the producer-set hint only as debug metadata; never trust it as the
  # canonical key. Log when it disagrees with the attested-field-derived key so
  # producer drift is observable.
  defp maybe_record_series_hint(metadata, hint, series_key) do
    case non_empty(hint) do
      nil ->
        metadata

      hint when hint != series_key ->
        SeriesHintDrift.record(:sample_extractor, hint, series_key)
        Map.put_new(metadata, "series_identity_hint", hint)

      hint ->
        Map.put_new(metadata, "series_identity_hint", hint)
    end
  end

  defp fallback_metric_type(%{kind: :METRIC_KIND_SUM}), do: "sum"
  defp fallback_metric_type(%{kind: :METRIC_KIND_HISTOGRAM}), do: "histogram"
  defp fallback_metric_type(_metric), do: "gauge"

  defp metric_kind(:METRIC_KIND_GAUGE), do: "gauge"
  defp metric_kind(:METRIC_KIND_SUM), do: "sum"
  defp metric_kind(:METRIC_KIND_HISTOGRAM), do: "histogram"
  defp metric_kind(_kind), do: nil

  defp metric_temporality(:METRIC_TEMPORALITY_DELTA), do: "delta"
  defp metric_temporality(:METRIC_TEMPORALITY_CUMULATIVE), do: "cumulative"
  defp metric_temporality(_temporality), do: nil

  defp metric_value_type(:METRIC_VALUE_TYPE_DOUBLE), do: "double"
  defp metric_value_type(:METRIC_VALUE_TYPE_INT64), do: "int64"
  defp metric_value_type(:METRIC_VALUE_TYPE_UINT64), do: "uint64"
  defp metric_value_type(:METRIC_VALUE_TYPE_BOOL), do: "bool"
  defp metric_value_type(:METRIC_VALUE_TYPE_STRING), do: "string"
  defp metric_value_type(_type), do: nil

  defp positive_int(value) when is_integer(value) and value > 0, do: value
  defp positive_int(_value), do: nil

  defp scale(value) when is_number(value) and value != 0, do: value
  defp scale(_value), do: nil

  defp non_empty(value) when is_binary(value) and value != "", do: value
  defp non_empty(_value), do: nil

  defp merge_ingress_metadata(metadata, ingress_metadata)
       when is_map(metadata) and map_size(ingress_metadata) > 0,
       do: Map.merge(metadata, ingress_metadata)

  defp merge_ingress_metadata(metadata, _ingress_metadata), do: metadata

  defp event_id({:ingress_id, ingress_id}, sample_hash), do: "#{ingress_id}:#{sample_hash}"
  defp event_id({:event_id, event_id}, _sample_hash), do: event_id
  defp event_id(nil, sample_hash), do: sample_hash

  defp order_key({:ingress_id, ingress_id}, order_timestamp, timestamp, sample_hash) do
    {order_timestamp, ingress_id, timestamp || 0, sample_hash}
  end

  defp order_key({:event_id, event_id}, order_timestamp, timestamp, sample_hash) do
    {order_timestamp, event_id, timestamp || 0, sample_hash}
  end

  defp order_key(nil, order_timestamp, timestamp, sample_hash) do
    {order_timestamp, sample_hash, timestamp || 0, sample_hash}
  end

  defp explicit_event_identity(metadata) when is_map(metadata) do
    cond do
      value =
          non_empty_binary_value(metadata, [:ingress_id, "ingress_id", :ingressId, "ingressId"]) ->
        {:ingress_id, value}

      value = non_empty_binary_value(metadata, [:event_id, "event_id", :eventId, "eventId"]) ->
        {:event_id, value}

      value = non_empty_binary_value(metadata, [:uuid, "uuid", :uuidv8, "uuidv8"]) ->
        {:event_id, value}

      value =
          non_empty_binary_value(metadata, [:message_id, "message_id", :messageId, "messageId"]) ->
        {:event_id, value}

      true ->
        nil
    end
  end

  defp non_empty_binary_value(metadata, aliases) do
    Enum.find_value(aliases, fn key ->
      case Map.get(metadata, key) do
        value when is_binary(value) and value != "" -> value
        _ -> nil
      end
    end)
  end

  defp order_timestamp(timestamp, metadata) do
    ingress_timestamp(metadata) || timestamp || 0
  end

  defp ingress_timestamp(metadata) when is_map(metadata) do
    Map.get(metadata, :ingress_timestamp_unix_nano) ||
      Map.get(metadata, "ingress_timestamp_unix_nano") ||
      Map.get(metadata, :ingressTimestampUnixNano) ||
      Map.get(metadata, "ingressTimestampUnixNano")
  end

  defp sample_hash(series_key, timestamp, subject, value) do
    :sha256
    |> :crypto.hash([
      to_string(series_key),
      ?|,
      to_string(timestamp),
      ?|,
      to_string(subject),
      ?|,
      to_string(value)
    ])
    |> Base.encode16(case: :lower)
  end

  defp header_value(headers, key) when is_map(headers) do
    headers
    |> Enum.find_value(fn {header_key, value} ->
      if normalize_header_key(header_key) == key, do: normalize_header_value(value)
    end)
    |> non_empty_string()
  end

  defp header_value(headers, key) when is_list(headers) do
    headers
    |> Enum.find_value(fn
      {header_key, value} ->
        if normalize_header_key(header_key) == key, do: normalize_header_value(value)

      _other ->
        nil
    end)
    |> non_empty_string()
  end

  defp header_value(_headers, _key), do: nil

  defp normalize_header_key(key) when is_binary(key), do: String.downcase(key)

  defp normalize_header_key(key) when is_atom(key),
    do: key |> Atom.to_string() |> String.downcase()

  defp normalize_header_key(key) when is_list(key) do
    key |> to_string() |> String.downcase()
  rescue
    _ -> ""
  end

  defp normalize_header_key(_key), do: ""

  defp normalize_header_value(value) when is_binary(value), do: value
  defp normalize_header_value([first | _rest]) when is_binary(first), do: first

  defp normalize_header_value(value) when is_list(value) do
    to_string(value)
  rescue
    _ -> nil
  end

  defp normalize_header_value(value) when is_atom(value) and not is_nil(value),
    do: Atom.to_string(value)

  defp normalize_header_value(_value), do: nil

  defp non_empty_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp non_empty_string(_value), do: nil

  defp parse_non_negative_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed >= 0 -> parsed
      _ -> nil
    end
  end

  defp parse_non_negative_integer(_value), do: nil

  defp maybe_put_metadata(map, _key, nil), do: map
  defp maybe_put_metadata(map, key, value), do: Map.put(map, key, value)

  defp subject(metadata) when is_map(metadata),
    do: metadata[:base_subject] || metadata[:subject] || ""

  defp subject(_metadata), do: ""
end
