defmodule ServiceRadarWebNGWeb.DiagnosticsLive.Mtr.Params do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]

  alias ServiceRadar.Observability.MtrSettingsRuntime
  alias ServiceRadarWebNGWeb.DiagnosticsLive.Mtr.Config

  def parse_page(nil), do: 1

  def parse_page(page) when is_binary(page) do
    case Integer.parse(page) do
      {value, ""} when value > 0 -> value
      _ -> 1
    end
  end

  def parse_page(page) when is_integer(page) and page > 0, do: page
  def parse_page(_), do: 1

  def parse_limit(nil, default), do: default

  def parse_limit(limit, default) when is_binary(limit) do
    case Integer.parse(limit) do
      {value, ""} -> parse_limit(value, default)
      _ -> default
    end
  end

  def parse_limit(limit, _default) when is_integer(limit) do
    limit |> max(1) |> min(Config.max_limit())
  end

  def parse_limit(_limit, default), do: default

  def default_page_size do
    MtrSettingsRuntime.settings()
    |> Map.get(:mtr_history_page_size_default, Config.default_limit())
    |> parse_limit(Config.default_limit())
  rescue
    _ -> Config.default_limit()
  end

  def default_history_window do
    MtrSettingsRuntime.settings()
    |> Map.get(:mtr_default_history_window, "last_30d")
    |> normalize_text()
    |> case do
      "" -> "last_30d"
      window -> window
    end
  rescue
    _ -> "last_30d"
  end

  def sync_srql_state(socket, params, uri) do
    query = normalize_text(Map.get(params, "q"))

    srql =
      (socket.assigns[:srql] || %{})
      |> Map.put(:enabled, true)
      |> Map.put(:entity, "mtr_traces")
      |> Map.put(:page_path, uri_path(uri, "/diagnostics/mtr"))
      |> Map.put(:query, default_query(query, socket.assigns.limit))
      |> Map.put(:draft, default_query(query, socket.assigns.limit))

    assign(socket, :srql, srql)
  end

  def patch_path(params) do
    cleaned = Map.reject(params, fn {_k, v} -> is_nil(v) or v == "" end)
    "/diagnostics/mtr?" <> URI.encode_query(cleaned)
  end

  def pagination_params(query, page, limit, target, agent) do
    %{"q" => query, "page" => page, "limit" => limit, "target" => target, "agent" => agent}
  end

  def extra_query_params(socket) do
    %{"target" => socket.assigns.filter_target, "agent" => socket.assigns.filter_agent, "page" => 1}
  end

  def maybe_put_query(params, ""), do: Map.delete(params, "q")
  def maybe_put_query(params, query), do: Map.put(params, "q", query)

  def normalize_text(nil), do: ""
  def normalize_text(value) when is_binary(value), do: String.trim(value)
  def normalize_text(value), do: value |> to_string() |> String.trim()

  defp uri_path(uri, fallback) when is_binary(uri) do
    case URI.parse(uri) do
      %URI{path: path} when is_binary(path) and path != "" -> path
      _ -> fallback
    end
  end

  defp uri_path(_uri, fallback), do: fallback

  defp default_query("", limit), do: "in:mtr_traces time:#{default_history_window()} sort:time:desc limit:#{limit}"
  defp default_query(query, _limit), do: query
end
