defmodule ServiceRadar.Observability.StatefulAlertEngine.Bucketing do
  @moduledoc """
  Time-bucketing and sliding-window arithmetic for rule snapshots: mapping a
  record timestamp to its bucket start, advancing/pruning buckets across the
  configured window, summing the window count, and (de)serializing the
  integer-keyed bucket-count map for persistence.
  """

  import ServiceRadar.Observability.StatefulAlertEngine.Helpers
  import ServiceRadar.Observability.StatefulAlertEngine.Record

  def record_bucket_start(record, bucket_seconds) do
    record
    |> record_timestamp()
    |> to_bucket_start(bucket_seconds)
  end

  def to_bucket_start(%DateTime{} = dt, bucket_seconds) when is_integer(bucket_seconds) do
    unix = DateTime.to_unix(dt, :second)
    unix - rem(unix, bucket_seconds)
  end

  def to_bucket_start(%DateTime{} = dt), do: DateTime.to_unix(dt, :second)
  def to_bucket_start(nil), do: nil
  def to_bucket_start(value) when is_integer(value), do: value

  def from_bucket_start(unix) when is_integer(unix) do
    DateTime.from_unix!(unix, :second)
  end

  def advance_bucket(bucket_counts, current_bucket_start, bucket_start, _rule) do
    current = current_bucket_start || bucket_start

    if bucket_start > current do
      {bucket_counts, bucket_start, true}
    else
      {bucket_counts, current, false}
    end
  end

  def prune_buckets(bucket_counts, current_bucket_start, window_seconds, bucket_seconds) do
    min_bucket = current_bucket_start - (window_seconds - bucket_seconds)

    bucket_counts
    |> Enum.filter(fn {bucket, _} -> bucket >= min_bucket end)
    |> Map.new()
  end

  def window_count(bucket_counts) do
    bucket_counts
    |> Map.values()
    |> Enum.sum()
  end

  def record_bucket_increment(record) do
    if metric_record?(record) do
      if fetch_attr(record, :__stateful_alert_violation__) do
        1
      else
        0
      end
    else
      1
    end
  end

  def normalize_bucket_counts(bucket_counts) when is_map(bucket_counts) do
    Enum.reduce(bucket_counts, %{}, fn {key, value}, acc ->
      case Integer.parse(to_string(key)) do
        {bucket, _} -> Map.put(acc, bucket, value)
        :error -> acc
      end
    end)
  end

  def stringify_bucket_counts(bucket_counts) do
    Enum.reduce(bucket_counts, %{}, fn {key, value}, acc ->
      Map.put(acc, to_string(key), value)
    end)
  end

  def add_seconds(%DateTime{} = dt, seconds) when is_integer(seconds) do
    DateTime.add(dt, seconds, :second)
  end
end
