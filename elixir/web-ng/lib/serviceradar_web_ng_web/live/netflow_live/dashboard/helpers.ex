defmodule ServiceRadarWebNGWeb.NetflowLive.Dashboard.Helpers do
  @moduledoc false

  alias ServiceRadar.ReferenceData.ServicePorts

  Module.register_attribute(__MODULE__, :sobelow_skip, accumulate: true)

  def time_windows do
    [
      {"1h", "Last 1 Hour"},
      {"6h", "Last 6 Hours"},
      {"24h", "Last 24 Hours"},
      {"7d", "Last 7 Days"},
      {"30d", "Last 30 Days"}
    ]
  end

  def unit_modes do
    [
      {"bps", "Bits/sec"},
      {"Bps", "Bytes/sec"},
      {"pps", "Packets/sec"}
    ]
  end

  def metric_modes do
    [
      {"bytes", "By Bytes"},
      {"packets", "By Packets"}
    ]
  end

  def sections do
    [
      {"overview", "Overview"},
      {"topn", "Top Lists"},
      {"traffic", "Traffic"},
      {"capacity", "Interfaces"},
      {"all", "Show All"}
    ]
  end

  def section_visible?("all", _section), do: true
  def section_visible?(current, section), do: current == section

  def safe_parse_int(val) when is_integer(val), do: {:ok, val}

  def safe_parse_int(val) when is_binary(val) do
    case Integer.parse(val) do
      {i, ""} -> {:ok, i}
      _ -> :error
    end
  end

  def safe_parse_int(_), do: :error

  def validate_param(nil, _allowed, default), do: default

  def validate_param(value, allowed, default) do
    if Enum.any?(allowed, fn {k, _} -> k == value end), do: value, else: default
  end

  def normalize_optional_query(nil), do: nil

  def normalize_optional_query(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  def normalize_optional_query(_), do: nil

  def base_flow_query(nil, tw), do: "in:flows time:last_#{tw}"

  def base_flow_query(query, tw) when is_binary(query) do
    query
    |> String.trim()
    |> ensure_flow_entity()
    |> ensure_flow_time_window(tw)
  end

  def ensure_flow_entity(query) do
    if String.contains?(query, "in:flows"), do: query, else: "in:flows #{query}"
  end

  def ensure_flow_time_window(query, tw) do
    if Regex.match?(~r/\btime:/, query), do: query, else: "#{query} time:last_#{tw}"
  end

  def patch_params(socket, overrides) do
    %{
      tw: socket.assigns.time_window,
      unit: socket.assigns.unit_mode,
      metric: socket.assigns.metric_mode,
      section: socket.assigns.section,
      q: socket.assigns.query
    }
    |> Map.merge(overrides)
    |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)
    |> Map.new()
  end

  def bucket_seconds("1m"), do: 60
  def bucket_seconds("5m"), do: 300
  def bucket_seconds("15m"), do: 900
  def bucket_seconds("1h"), do: 3_600
  def bucket_seconds("6h"), do: 21_600
  def bucket_seconds(_), do: 300

  def time_window_seconds("1h"), do: 3_600
  def time_window_seconds("6h"), do: 21_600
  def time_window_seconds("24h"), do: 86_400
  def time_window_seconds("7d"), do: 604_800
  def time_window_seconds("30d"), do: 2_592_000
  def time_window_seconds(_), do: 3_600

  # §38.1: never let the covered span exceed the requested window (a too-long
  # span query can't inflate rates) or fall to/below zero (no div-by-zero).
  # nil / non-numeric → fall back to the requested window (today's behavior).
  def clamp_covered_span(raw_span, requested_seconds) when is_number(requested_seconds) do
    cond do
      not is_number(raw_span) -> requested_seconds
      raw_span <= 0 -> requested_seconds
      raw_span >= requested_seconds -> requested_seconds
      true -> max(1, raw_span)
    end
  end

  # §26.3: human-readable window label for the p95 column header (was hardcoded
  # "30d"). The @time_window tokens are already short and readable, so this is
  # a guarded passthrough.
  def time_window_label(tw) when tw in ["1h", "6h", "24h", "7d", "30d"], do: tw
  def time_window_label(_), do: "1h"

  def timeseries_bucket("1h"), do: "1m"
  def timeseries_bucket("6h"), do: "5m"
  def timeseries_bucket("24h"), do: "15m"
  def timeseries_bucket("7d"), do: "1h"
  def timeseries_bucket("30d"), do: "6h"
  def timeseries_bucket(_), do: "5m"

  # Escape a value for safe interpolation into an SRQL filter expression.
  # Wraps in double quotes and escapes any internal backslashes/double quotes.
  def srql_quote(value) when is_binary(value) do
    escaped = value |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")
    "\"#{escaped}\""
  end

  def srql_quote(value), do: srql_quote(to_string(value))

  # §26.2: a value labeled bps/pps is a per-second rate, so window-sum totals
  # (bytes/packets accumulated across the whole selected window) must be divided
  # by the window's seconds before the ×8 bytes→bits step. Without this divisor
  # the card/table showed the full window total mislabeled as a per-second rate.
  def primary_metric(_bytes, packets, "pps", window_seconds), do: per_second(packets, window_seconds)

  def primary_metric(bytes, _packets, "bps", window_seconds), do: per_second(bytes, window_seconds) * 8

  def primary_metric(bytes, _packets, _mode, _window_seconds), do: bytes

  def display_bandwidth(total_bytes, "bps", window_seconds), do: per_second(total_bytes, window_seconds) * 8

  def display_bandwidth(total_bytes, "pps", window_seconds), do: per_second(total_bytes, window_seconds)

  def display_bandwidth(total_bytes, _mode, _window_seconds), do: total_bytes

  # Guard a zero/negative window so a degenerate window never divides by zero;
  # falls back to a 1s rate (the raw total) rather than crashing the cell.
  def per_second(value, window_seconds) when is_number(value) and window_seconds > 0, do: value / window_seconds

  def per_second(value, _window_seconds) when is_number(value), do: value
  def per_second(nil, _window_seconds), do: 0

  def unit_suffix("bps"), do: "bps"
  def unit_suffix("Bps"), do: "B/s"
  def unit_suffix("pps"), do: "pps"
  def unit_suffix(_), do: ""

  @sobelow_skip ["XSS.Raw"]
  def format_port_cell(row) do
    port = to_string(row.port)

    app =
      case safe_parse_int(port) do
        {:ok, port_num} -> ServicePorts.label(port_num)
        :error -> nil
      end

    if app do
      Phoenix.HTML.raw(
        "#{port |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()}" <>
          " <span class=\"text-xs text-sr-muted\">(#{app |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()})</span>"
      )
    else
      port
    end
  end

  def format_p95_cell(row) do
    p95 = Map.get(row, :p95_bps, 0)
    if p95 > 0, do: ServiceRadarWebNGWeb.FlowStatComponents.format_si(p95 * 1.0, unit: "bps"), else: "—"
  end

  def format_capacity_cell(row) do
    cap = row.capacity_bps || 0
    if cap > 0, do: ServiceRadarWebNGWeb.FlowStatComponents.format_si(cap * 1.0, unit: "bps"), else: "N/A"
  end

  def format_bytes_cell(row, "pps", window_seconds) do
    val = per_second(row.packets || 0, window_seconds)
    ServiceRadarWebNGWeb.FlowStatComponents.format_si(val, unit: "pps")
  end

  def format_bytes_cell(row, unit_mode, window_seconds) do
    val = display_bandwidth(row.bytes || 0, unit_mode, window_seconds)
    ServiceRadarWebNGWeb.FlowStatComponents.format_si(val, unit: unit_suffix(unit_mode))
  end

  def format_primary_cell(row, _unit_mode, "packets", window_seconds) do
    val = per_second(row.packets || 0, window_seconds)
    ServiceRadarWebNGWeb.FlowStatComponents.format_si(val, unit: "pps")
  end

  def format_primary_cell(row, unit_mode, _metric_mode, window_seconds),
    do: format_bytes_cell(row, unit_mode, window_seconds)

  def primary_metric_col_label("pps", _metric_mode), do: "Packets/sec"
  def primary_metric_col_label(_unit_mode, "packets"), do: "Packets"
  def primary_metric_col_label(unit_mode, _metric_mode), do: unit_suffix(unit_mode)

  def get_field(payload, key) when is_map(payload) do
    Map.get(payload, key) || Map.get(payload, String.to_existing_atom(key))
  rescue
    ArgumentError -> Map.get(payload, key)
  end

  def row_payload(%{"payload" => payload}) when is_map(payload), do: payload
  def row_payload(%{} = row), do: row
  def row_payload(_), do: %{}

  def srql_results(srql_mod, query, scope) do
    case srql_mod.query(query, %{scope: scope}) do
      {:ok, %{"results" => results}} when is_list(results) -> results
      _ -> []
    end
  end

  def ash_results(%Ash.Page.Keyset{results: results}) when is_list(results), do: results
  def ash_results(results) when is_list(results), do: results
  def ash_results(_), do: []

  def to_number(nil), do: 0
  def to_number(n) when is_number(n), do: n

  def to_number(s) when is_binary(s) do
    case Float.parse(s) do
      {f, _} -> f
      :error -> 0
    end
  end

  def to_number(_), do: 0

  def safe_await_many(tasks, timeout) do
    tasks
    |> Task.yield_many(timeout)
    |> Enum.map(fn {task, result} ->
      case result do
        {:ok, {key, value}} when is_atom(key) ->
          {key, value}

        {:ok, _unexpected} ->
          nil

        _ ->
          Task.shutdown(task, :brutal_kill)
          nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Map.new()
  end

  def srql_module do
    Application.get_env(:serviceradar_web_ng, :srql_module, ServiceRadarWebNG.SRQL)
  end
end
