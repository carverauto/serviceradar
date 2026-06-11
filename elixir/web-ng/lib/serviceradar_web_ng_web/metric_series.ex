defmodule ServiceRadarWebNGWeb.MetricSeries do
  @moduledoc """
  Pure rate/series computation over OTLP metric point rows
  (`in:otel_metric_points`).

  Input rows are maps with string keys as returned by SRQL. Points are grouped
  into series by `attributes_hash`, sorted by timestamp (oldest first), and
  summarized per series:

    * `sum` with cumulative (or unspecified) temporality and a monotonic
      counter -> per-interval RATE: `delta / Δt seconds` between consecutive
      points. A value decrease is treated as a counter reset and the new value
      is used as the delta. Pairs with a non-positive Δt are skipped.
    * `sum` with delta temporality -> sum of point values over the window.
    * `gauge` (and non-monotonic cumulative sums) -> last value.
    * `histogram` -> count/sum summary (summed for delta temporality, latest
      snapshot otherwise).

  Everything here is intentionally side-effect free so it can be unit tested
  without a database.
  """

  @type series :: %{
          required(:attributes_hash) => String.t(),
          required(:attributes) => String.t() | nil,
          required(:metric_type) => String.t() | nil,
          required(:temporality) => String.t() | nil,
          required(:unit) => String.t() | nil,
          required(:kind) => :rate | :delta_sum | :gauge | :histogram,
          required(:point_count) => non_neg_integer(),
          optional(atom()) => any()
        }

  @doc """
  Group raw OTLP metric point rows into summarized series.

  Rows are grouped by `attributes_hash` (one series per distinct attribute
  set) and each series is sorted by timestamp before any delta/rate math, so
  out-of-order input is handled. Series are returned largest-first.
  """
  @spec series([map()]) :: [series()]
  def series(points) when is_list(points) do
    points
    |> Enum.filter(&is_map/1)
    |> Enum.group_by(&series_hash/1)
    |> Enum.map(fn {hash, group} -> build_series(hash, group) end)
    |> Enum.sort_by(&{-&1.point_count, &1.attributes_hash})
  end

  def series(_), do: []

  @doc """
  Compute per-interval rates for a chronologically sorted list of
  `{timestamp_us, value}` samples.

  Counter resets (a value decrease) use the new value as the delta; pairs with
  a non-positive Δt are skipped.
  """
  @spec rates([{integer(), number()}]) :: [float()]
  def rates(samples) when is_list(samples) do
    samples
    |> Enum.filter(fn
      {ts, value} -> is_integer(ts) and is_number(value)
      _ -> false
    end)
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.flat_map(fn [{t1, v1}, {t2, v2}] ->
      dt_seconds = (t2 - t1) / 1_000_000

      if dt_seconds > 0 do
        delta = if v2 < v1, do: v2, else: v2 - v1
        [delta / dt_seconds]
      else
        []
      end
    end)
  end

  def rates(_), do: []

  @doc "Parse a point timestamp into unix microseconds (nil when unusable)."
  @spec timestamp_us(map() | any()) :: integer() | nil
  def timestamp_us(%{"timestamp" => ts}), do: parse_ts(ts)
  def timestamp_us(_), do: nil

  defp series_hash(point) do
    case Map.get(point, "attributes_hash") do
      hash when is_binary(hash) -> hash
      other -> to_string(other || "")
    end
  end

  defp build_series(hash, group) do
    sorted = Enum.sort_by(group, &timestamp_us/1, &ts_before?/2)
    rep = List.last(sorted) || %{}
    kind = classify(rep)

    Map.merge(
      %{
        attributes_hash: hash,
        attributes: string_or_nil(Map.get(rep, "attributes")),
        metric_type: downcase_or_nil(Map.get(rep, "metric_type")),
        temporality: downcase_or_nil(Map.get(rep, "temporality")),
        unit: string_or_nil(Map.get(rep, "unit")),
        kind: kind,
        point_count: length(sorted)
      },
      summarize(kind, sorted)
    )
  end

  # nil timestamps sort first so they never form the "latest" sample, and the
  # rate pairing below skips pairs without a usable timestamp anyway.
  defp ts_before?(nil, _), do: true
  defp ts_before?(_, nil), do: false
  defp ts_before?(a, b), do: a <= b

  defp classify(point) do
    type = downcase_or_nil(Map.get(point, "metric_type"))
    temporality = downcase_or_nil(Map.get(point, "temporality"))

    case type do
      "histogram" ->
        :histogram

      "gauge" ->
        :gauge

      "sum" ->
        cond do
          temporality == "delta" -> :delta_sum
          # Non-monotonic cumulative sums (UpDownCounter) have no meaningful
          # rate; show them like gauges. Unknown monotonicity defaults to a
          # counter — reset detection keeps decreases safe either way.
          Map.get(point, "is_monotonic") == false -> :gauge
          true -> :rate
        end

      _ ->
        :gauge
    end
  end

  defp summarize(:rate, sorted) do
    computed =
      sorted
      |> Enum.map(fn point -> {timestamp_us(point), numeric_value(point)} end)
      |> rates()

    %{rates: computed, current_rate: List.last(computed)}
  end

  defp summarize(:delta_sum, sorted) do
    values = numeric_values(sorted)
    %{values: values, window_sum: Enum.sum(values)}
  end

  defp summarize(:gauge, sorted) do
    values = numeric_values(sorted)
    %{values: values, last_value: List.last(values)}
  end

  defp summarize(:histogram, sorted) do
    temporality = sorted |> List.last() |> Kernel.||(%{}) |> Map.get("temporality") |> downcase_or_nil()
    counts = sorted |> Enum.map(&numeric_field(&1, "count")) |> Enum.reject(&is_nil/1)
    sums = sorted |> Enum.map(&numeric_field(&1, "sum")) |> Enum.reject(&is_nil/1)

    if temporality == "delta" do
      %{histogram_count: round(Enum.sum(counts)), histogram_sum: Enum.sum(sums) * 1.0}
    else
      %{histogram_count: counts |> List.last() |> maybe_round(), histogram_sum: sums |> List.last() |> maybe_float()}
    end
  end

  defp numeric_values(sorted) do
    sorted
    |> Enum.map(&numeric_value/1)
    |> Enum.reject(&is_nil/1)
  end

  defp numeric_value(point), do: numeric_field(point, "value")

  defp numeric_field(point, key) do
    case Map.get(point, key) do
      value when is_number(value) ->
        value

      value when is_binary(value) ->
        case Float.parse(value) do
          {parsed, _} -> parsed
          :error -> nil
        end

      _ ->
        nil
    end
  end

  defp maybe_round(nil), do: nil
  defp maybe_round(value) when is_number(value), do: round(value)

  defp maybe_float(nil), do: nil
  defp maybe_float(value) when is_number(value), do: value * 1.0

  defp parse_ts(%DateTime{} = dt), do: DateTime.to_unix(dt, :microsecond)

  defp parse_ts(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _offset} ->
        DateTime.to_unix(dt, :microsecond)

      _ ->
        case NaiveDateTime.from_iso8601(ts) do
          {:ok, naive} -> naive |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix(:microsecond)
          _ -> nil
        end
    end
  end

  # Defensive: integer timestamps disambiguated by magnitude
  # (ns / us / ms / s) so producer drift cannot break the pane.
  defp parse_ts(ts) when is_integer(ts) do
    cond do
      ts > 100_000_000_000_000_000 -> div(ts, 1_000)
      ts > 100_000_000_000_000 -> ts
      ts > 100_000_000_000 -> ts * 1_000
      true -> ts * 1_000_000
    end
  end

  defp parse_ts(_), do: nil

  defp string_or_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp string_or_nil(_), do: nil

  defp downcase_or_nil(value) do
    case string_or_nil(value) do
      nil -> nil
      trimmed -> String.downcase(trimmed)
    end
  end
end
