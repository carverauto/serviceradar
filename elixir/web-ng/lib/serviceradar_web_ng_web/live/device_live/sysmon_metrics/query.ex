defmodule ServiceRadarWebNGWeb.DeviceLive.SysmonMetrics.Query do
  @moduledoc false

  import ServiceRadarWebNGWeb.DeviceLive.SysmonMetrics.Common, only: [escape_value: 1]

  alias ServiceRadarWebNG.SRQL.Batch

  # Aim for roughly this many points across the selected window, then snap to a
  # "nice" bucket size. 300 keeps a 24h view at the familiar 5m bucket while a
  # 1h view drops to ~15s and a 7d view coarsens to ~1h.
  @bucket_target_points 299

  # Candidate bucket sizes (seconds => SRQL bucket token), ascending.
  @nice_buckets [
    {1, "1s"},
    {5, "5s"},
    {10, "10s"},
    {15, "15s"},
    {30, "30s"},
    {60, "1m"},
    {120, "2m"},
    {300, "5m"},
    {600, "10m"},
    {900, "15m"},
    {1800, "30m"},
    {3600, "1h"},
    {7200, "2h"},
    {21_600, "6h"},
    {43_200, "12h"},
    {86_400, "1d"}
  ]

  @default_bucket "5m"

  @unit_seconds %{
    "s" => 1,
    "m" => 60,
    "h" => 3_600,
    "d" => 86_400,
    "w" => 604_800
  }

  @doc """
  Chooses a downsample bucket sized to the selected time range so short windows
  render fine-grained points instead of the fixed 5m bucket.

  Accepts the same time-range tokens used in metric queries:

    * relative windows like `"last_1h"`, `"last_24h"`, `"last_7d"`
    * absolute ranges like `"[2026-06-26T06:30:00Z,2026-06-26T08:30:00Z]"`

  Falls back to `"5m"` when the range cannot be interpreted.
  """
  @spec bucket_for_time_range(term()) :: String.t()
  def bucket_for_time_range(time_range) do
    case window_seconds(time_range) do
      seconds when is_integer(seconds) and seconds > 0 ->
        pick_bucket(seconds / @bucket_target_points)

      _ ->
        @default_bucket
    end
  end

  def bucket_seconds(bucket) when is_binary(bucket), do: relative_window_seconds(bucket)
  def bucket_seconds(_bucket), do: nil

  def query_bucket_seconds(query) when is_binary(query) do
    case Regex.run(~r/(?:^|\s)bucket:(\S+)/, query) do
      [_, bucket] -> bucket_seconds(bucket)
      _ -> nil
    end
  end

  def query_bucket_seconds(_query), do: nil

  def requested_window(time_range, now \\ DateTime.utc_now())

  def requested_window("last_" <> duration, %DateTime{} = now) do
    case relative_window_seconds(duration) do
      seconds when is_integer(seconds) and seconds > 0 -> {DateTime.add(now, -seconds, :second), now}
      _ -> nil
    end
  end

  def requested_window("[" <> _ = range, _now) do
    with true <- String.ends_with?(range, "]"),
         [start_raw, end_raw] <-
           range |> String.trim_leading("[") |> String.trim_trailing("]") |> String.split(",", parts: 2),
         {:ok, start_dt, _} <- DateTime.from_iso8601(String.trim(start_raw)),
         {:ok, end_dt, _} <- DateTime.from_iso8601(String.trim(end_raw)),
         true <- DateTime.before?(start_dt, end_dt) do
      {start_dt, end_dt}
    else
      _ -> nil
    end
  end

  def requested_window(_range, _now), do: nil

  defp pick_bucket(target_seconds) do
    Enum.find_value(@nice_buckets, "#{ceil(target_seconds / 86_400)}d", fn {seconds, token} ->
      if seconds >= target_seconds, do: token
    end)
  end

  defp window_seconds(value) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      String.starts_with?(trimmed, "last_") ->
        relative_window_seconds(String.trim_leading(trimmed, "last_"))

      String.starts_with?(trimmed, "[") and String.ends_with?(trimmed, "]") ->
        absolute_window_seconds(trimmed)

      true ->
        nil
    end
  end

  defp window_seconds(_value), do: nil

  defp relative_window_seconds(rest) do
    case Regex.run(~r/^(\d+)([a-z])$/, rest) do
      [_, amount, unit] ->
        case Map.get(@unit_seconds, unit) do
          nil -> nil
          unit_seconds -> String.to_integer(amount) * unit_seconds
        end

      _ ->
        nil
    end
  end

  defp absolute_window_seconds(bracketed) do
    case requested_window(bracketed) do
      {start_dt, end_dt} -> ceil(DateTime.diff(end_dt, start_dt, :microsecond) / 1_000_000)
      nil -> nil
    end
  end

  @doc """
  Builds the device filter token for a set of device UIDs. A single UID uses an
  exact `uid:"x"` match; multiple UIDs (a merged device's historical identities)
  collapse into a single SRQL `IN` list `uid:("a","b")` so one query spans every
  identity the metrics were written under.
  """
  @spec device_uid_filter_tokens([String.t()]) :: [String.t()]
  def device_uid_filter_tokens([]), do: []

  def device_uid_filter_tokens([single]), do: [~s|uid:"#{escape_value(single)}"|]

  def device_uid_filter_tokens(uids) when is_list(uids) do
    values = Enum.map_join(uids, ",", fn uid -> ~s|"#{escape_value(uid)}"| end)
    [~s|uid:(#{values})|]
  end

  def timeseries_metric_query(metric_type, metric_name, filter_tokens, series_field, limit, opts \\ []) do
    series_field =
      case series_field do
        nil -> nil
        "" -> nil
        other -> other |> to_string() |> String.trim()
      end

    tokens =
      if Keyword.get(opts, :bucket?, true) do
        [
          "in:timeseries_metrics",
          ~s|metric_type:"#{escape_value(metric_type)}"|,
          ~s|metric_name:"#{escape_value(metric_name)}"|,
          "time:#{Keyword.get(opts, :time_range, "last_24h")}",
          "bucket:#{Keyword.get(opts, :bucket, "5m")}",
          "agg:#{Keyword.get(opts, :agg, "avg")}"
        ]
      else
        [
          "in:timeseries_metrics",
          ~s|metric_type:"#{escape_value(metric_type)}"|,
          ~s|metric_name:"#{escape_value(metric_name)}"|,
          "time:#{Keyword.get(opts, :time_range, "last_24h")}"
        ]
      end

    tokens =
      tokens
      |> maybe_add_token("series", series_field)
      |> Kernel.++(filter_tokens)
      |> Kernel.++(["sort:timestamp:desc"])
      |> maybe_add_limit(limit)

    Enum.join(tokens, " ")
  end

  def summary_query(filter_tokens, limit, opts) do
    [
      "in:timeseries_metrics",
      ~s|metric_type:("sysmon.cpu","sysmon.memory","sysmon.disk")|,
      ~s|metric_name:("cpu.usage_percent","memory.used_percent","disk.used_percent")|,
      "time:#{Keyword.get(opts, :time_range, "last_24h")}",
      "bucket:#{Keyword.get(opts, :bucket, "5m")}",
      "agg:avg",
      "series:metric_name"
    ]
    |> Kernel.++(filter_tokens)
    |> Kernel.++(["sort:timestamp:desc", "limit:#{limit}"])
    |> Enum.join(" ")
  end

  def run(srql_module, query, scope, opts) do
    deadline = Keyword.get(opts, :deadline)

    if is_integer(deadline) and deadline <= System.monotonic_time(:millisecond) do
      {:error, :timeout}
    else
      srql_module.query(query, %{scope: scope, deadline: deadline})
    end
  end

  def run_batch(srql_module, queries, scope, opts) do
    deadline = Keyword.get(opts, :deadline)

    result =
      cond do
        is_integer(deadline) and deadline <= System.monotonic_time(:millisecond) ->
          {:error, :timeout}

        Code.ensure_loaded?(srql_module) and function_exported?(srql_module, :query_batch, 2) ->
          srql_module.query_batch(queries, %{scope: scope, deadline: deadline})

        true ->
          {:ok, Batch.execute_separately(queries, &run(srql_module, &1, scope, opts))}
      end

    case result do
      {:ok, results} -> results
      {:error, _} = error -> Map.new(queries, fn {key, _query} -> {key, error} end)
    end
  end

  defp maybe_add_limit(tokens, nil), do: tokens
  defp maybe_add_limit(tokens, ""), do: tokens
  defp maybe_add_limit(tokens, limit), do: tokens ++ ["limit:#{limit}"]

  defp maybe_add_token(tokens, _key, nil), do: tokens
  defp maybe_add_token(tokens, _key, ""), do: tokens

  defp maybe_add_token(tokens, key, value) do
    tokens ++ ["#{key}:#{value}"]
  end
end
