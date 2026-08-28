defmodule ServiceRadarWebNGWeb.ObservabilityPaths do
  @moduledoc """
  Intent URLs for the unified observability LiveView.

  Path = tab (`/observability/events`), query string = investigation (`q=…`
  plus view chrome). Legacy `?tab=` is accepted and can be rewritten here.
  """

  @tabs ~w(logs traces metrics events alerts netflows)

  @doc "Known observability tab identifiers."
  def tabs, do: @tabs

  @doc "True when `tab` is a primary observability list pane."
  def tab?(tab) when is_binary(tab), do: tab in @tabs
  def tab?(_), do: false

  @doc """
  Build an intent URL for a tab.

  Drops position noise (`cursor`, `page`, and normally `limit`) and legacy
  `tab` from query params. NetFlow retains a legacy URL `limit` only when its
  SRQL query has no authoritative `limit:` token. Example:

      path("events", q: "in:events time:last_7d")
      # => "/observability/events?q=in%3Aevents+time%3Alast_7d"
  """
  def path(tab, query_params \\ %{})

  def path(tab, query_params) when is_binary(tab) and tab in @tabs do
    base = "/observability/#{tab}"
    qs = encode_query(query_params, tab)

    if qs == "" do
      base
    else
      base <> "?" <> qs
    end
  end

  def path(tab, query_params) when is_atom(tab) do
    path(Atom.to_string(tab), query_params)
  end

  def path(_tab, _query_params), do: "/observability/logs"

  @spec events_range_path(DateTime.t(), DateTime.t()) :: String.t()
  def events_range_path(%DateTime{} = start_time, %DateTime{} = end_time) do
    query =
      "in:events time:[#{DateTime.to_iso8601(start_time)},#{DateTime.to_iso8601(end_time)}] " <>
        "sort:time:desc limit:20"

    path("events", %{q: query})
  end

  @doc "Map a request path to a tab, or nil when the path is not a tab route."
  def tab_from_path(path) when is_binary(path) do
    case path |> String.split("?", parts: 2) |> hd() |> String.split("/", trim: true) do
      ["observability", tab | _] when tab in @tabs -> tab
      ["logs"] -> "logs"
      _ -> nil
    end
  end

  def tab_from_path(_), do: nil

  @doc "Map a LiveView live_action atom to a tab string."
  def tab_from_live_action(action) when action in [:logs, :traces, :metrics, :events, :alerts, :netflows] do
    Atom.to_string(action)
  end

  def tab_from_live_action(_), do: nil

  @doc """
  Resolve the active tab from live_action, path, and legacy `?tab=`.

  Preference: live_action → path segment → query `tab` → default.
  """
  def resolve_tab(live_action, path, params, default \\ "logs") do
    cond do
      tab = tab_from_live_action(live_action) -> tab
      tab = tab_from_path(path) -> tab
      tab = normalize_tab_param(Map.get(params || %{}, "tab")) -> tab
      true -> default
    end
  end

  @doc """
  When the client still uses `/observability?tab=events`, return a path-based
  target for a replace navigation. Returns nil when already canonical.
  """
  def legacy_tab_redirect(path, params) when is_binary(path) and is_map(params) do
    path_only = path |> String.split("?", parts: 2) |> hd()
    path_tab = tab_from_path(path_only)
    param_tab = normalize_tab_param(Map.get(params, "tab"))

    cond do
      # Bare /observability?tab=X → /observability/X?...
      path_only in ["/observability", "/logs"] and is_binary(param_tab) ->
        path(param_tab, Map.delete(params, "tab"))

      # /observability/events?tab=events → strip redundant tab=
      is_binary(path_tab) and param_tab in [path_tab, nil] and Map.has_key?(params, "tab") ->
        path(path_tab, Map.delete(params, "tab"))

      # Mismatched tab param vs path — path wins, drop param
      is_binary(path_tab) and is_binary(param_tab) and param_tab != path_tab ->
        path(path_tab, Map.delete(params, "tab"))

      true ->
        nil
    end
  end

  def legacy_tab_redirect(_path, _params), do: nil

  defp normalize_tab_param(tab) when tab in @tabs, do: tab
  defp normalize_tab_param(_), do: nil

  defp encode_query(params, tab) when is_map(params) do
    position_keys =
      if tab == "netflows",
        do: ["tab", "cursor", "page", "_format", "_mounts"],
        else: ["tab", "limit", "cursor", "page", "_format", "_mounts"]

    params
    |> Enum.reduce(%{}, fn
      {k, v}, acc when is_atom(k) -> Map.put(acc, Atom.to_string(k), v)
      {k, v}, acc when is_binary(k) -> Map.put(acc, k, v)
      _, acc -> acc
    end)
    |> Map.drop(position_keys)
    |> Map.reject(fn {_k, v} -> is_nil(v) or v == "" end)
    |> URI.encode_query()
  end

  defp encode_query(_params, _tab), do: ""
end
