defmodule ServiceRadarWebNGWeb.NetflowLive.ChartState do
  @moduledoc false

  def disabled_from_srql(%{enabled: false}) do
    %{
      kind: :disabled,
      title: "Flow charting disabled",
      detail: "SRQL-backed charting is disabled for this deployment.",
      link_href: "/admin/collectors",
      link_label: "Collector setup"
    }
  end

  def disabled_from_srql(_srql), do: nil

  def for_chart_payload(graph, keys, points) do
    if empty_series?(keys) or empty_series?(points) do
      no_data(graph)
    end
  end

  def for_sankey_edges(edges) do
    if empty_series?(edges) do
      no_data("sankey")
    end
  end

  def no_data("sankey") do
    %{
      kind: :no_data,
      title: "No Sankey data",
      detail: "The flow query succeeded, but no conversations matched this time window and dimension set.",
      link_href: "/settings/flows",
      link_label: "Flow settings"
    }
  end

  def no_data(_graph) do
    %{
      kind: :no_data,
      title: "No chart data",
      detail: "The chart query succeeded, but no flow buckets matched this time window and filter set.",
      link_href: "/settings/flows",
      link_label: "Flow settings"
    }
  end

  def query_error(prefix, reason) do
    %{
      kind: :query_error,
      title: "#{safe_prefix(prefix)} failed",
      detail: format_reason(reason),
      link_href: nil,
      link_label: nil
    }
  end

  defp empty_series?(value), do: not (is_list(value) and value != [])

  defp safe_prefix(prefix) when is_binary(prefix) do
    prefix
    |> String.trim()
    |> case do
      "" -> "Chart query"
      value -> value
    end
  end

  defp safe_prefix(_prefix), do: "Chart query"

  defp format_reason(reason) when is_binary(reason) do
    reason
    |> String.trim()
    |> case do
      "" -> "The query returned an empty error message."
      value -> value
    end
  end

  defp format_reason(reason), do: inspect(reason)
end
