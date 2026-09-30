defmodule ServiceRadarAgentGateway.MetricBatchSplit do
  @moduledoc """
  Splits an encoded `MetricBatch` into parts that stay under a byte budget.

  NATS rejects a publish whose payload exceeds the server-advertised
  `max_payload` and closes the connection, so a single oversized metric batch
  must never reach the wire as one message. This module distributes the
  batch's metrics across several batches whose encoded size stays under the
  budget, preserving the batch envelope (schema version, resource, ingest
  identity, ingress id and timestamps — including gateway attestation) on
  every part.

  A metric whose points alone exceed the budget is split into point shards:
  each shard carries the metric's header fields with a subset of its points.
  A single point that cannot fit even in an otherwise-empty part is dropped
  and reported as `dropped_points` — publishing it would only recreate the
  connection-dropping violation this splitter exists to prevent.

  Sizes are computed from exact wire arithmetic (each repeated message field
  entry is encoded independently as tag + varint length + bytes), so packed
  part sizes match the budget checks without re-encoding the accumulated
  part for every appended item.
  """

  alias Serviceradar.Metric.V1.Metric
  alias Serviceradar.Metric.V1.MetricBatch
  alias Serviceradar.Metric.V1.MetricPoint

  # Field 20 (MetricBatch.metrics and Metric.points) is the only repeated
  # message field either message carries; its wire tag is two bytes.
  @repeated_field_tag_bytes 2

  @type split_result :: %{
          required(:parts) => [MetricBatch.t()],
          required(:original_bytes) => non_neg_integer(),
          required(:dropped_points) => non_neg_integer()
        }

  @doc """
  Splits `batch` so every part's encoded size stays under `max_bytes`.

  Returns the parts (in original metric order), the encoded size of the
  original batch, and the number of points dropped because a single point
  could not fit under the budget. When the whole batch already fits it is
  returned unchanged as the single part.
  """
  @spec split(MetricBatch.t(), pos_integer()) :: split_result()
  def split(%MetricBatch{} = batch, max_bytes) when is_integer(max_bytes) and max_bytes > 0 do
    envelope = %{batch | metrics: []}
    envelope_size = encoded_size(envelope)
    metrics = batch.metrics || []
    original_bytes = envelope_size + metrics_size(metrics)

    if original_bytes <= max_bytes do
      %{parts: [batch], original_bytes: original_bytes, dropped_points: 0}
    else
      {items, dropped_points} = expand_oversized_metrics(metrics, envelope_size, max_bytes)

      %{
        parts: pack_parts(envelope, envelope_size, items, max_bytes),
        original_bytes: original_bytes,
        dropped_points: dropped_points
      }
    end
  end

  defp expand_oversized_metrics(metrics, envelope_size, max_bytes) do
    metrics
    |> Enum.reduce({[], 0}, fn metric, {items, dropped} ->
      if envelope_size + metric_item_cost(metric) <= max_bytes do
        {[metric | items], dropped}
      else
        {shards, shard_dropped} = split_metric_points(metric, envelope_size, max_bytes)
        {Enum.reverse(shards, items), dropped + shard_dropped}
      end
    end)
    |> then(fn {items, dropped} -> {Enum.reverse(items), dropped} end)
  end

  # Splits one metric whose own encoded size exceeds the budget into shards
  # (same header, subset of points) that each fit alongside the envelope.
  defp split_metric_points(%Metric{} = metric, envelope_size, max_bytes) do
    header = %{metric | points: []}
    header_size = encoded_size(header)

    metric.points
    |> Enum.reduce({[], [], 0, 0}, fn point, {shards, current, current_size, dropped} ->
      cost = point_item_cost(point)

      cond do
        current != [] and envelope_size + wrapped_size(header_size + current_size + cost) > max_bytes ->
          shard = %{header | points: Enum.reverse(current)}
          {[shard | shards], [point], header_size + cost, dropped}

        current == [] and envelope_size + wrapped_size(header_size + cost) > max_bytes ->
          # A lone point that cannot fit under the budget can never be
          # published; report it dropped rather than sending a message the
          # broker is guaranteed to reject.
          {shards, current, current_size, dropped + 1}

        true ->
          {shards, [point | current], current_size + cost, dropped}
      end
    end)
    |> case do
      {shards, [], _current_size, dropped} ->
        {Enum.reverse(shards), dropped}

      {shards, current, _current_size, dropped} ->
        {Enum.reverse([%{header | points: Enum.reverse(current)} | shards]), dropped}
    end
  end

  defp pack_parts(envelope, envelope_size, items, max_bytes) do
    items
    |> Enum.reduce({[], [], envelope_size}, fn item, {parts, current, current_size} ->
      cost = metric_item_cost(item)

      if current != [] and current_size + cost > max_bytes do
        {[build_part(envelope, Enum.reverse(current)) | parts], [item], envelope_size + cost}
      else
        {parts, [item | current], current_size + cost}
      end
    end)
    |> case do
      {parts, [], _current_size} ->
        Enum.reverse(parts)

      {parts, current, _current_size} ->
        Enum.reverse([build_part(envelope, Enum.reverse(current)) | parts])
    end
  end

  defp build_part(envelope, metrics), do: %{envelope | metrics: metrics}

  defp metrics_size(metrics), do: Enum.reduce(metrics, 0, &(&2 + metric_item_cost(&1)))

  defp metric_item_cost(%Metric{} = metric), do: wrapped_size(encoded_size(metric))

  defp point_item_cost(%MetricPoint{} = point), do: wrapped_size(encoded_size(point))

  # Bytes a repeated field entry adds to its parent message: wire tag plus
  # varint length prefix plus the entry bytes.
  defp wrapped_size(entry_size) do
    @repeated_field_tag_bytes + varint_size(entry_size) + entry_size
  end

  defp encoded_size(message) do
    message
    |> encode_message()
    |> IO.iodata_length()
  end

  defp encode_message(%MetricBatch{} = message), do: MetricBatch.encode(message)
  defp encode_message(%Metric{} = message), do: Metric.encode(message)
  defp encode_message(%MetricPoint{} = message), do: MetricPoint.encode(message)

  defp varint_size(value) when is_integer(value) and value >= 0 do
    varint_size(value, 1)
  end

  defp varint_size(value, acc) when value < 128, do: acc
  defp varint_size(value, acc), do: varint_size(div(value, 128), acc + 1)
end
