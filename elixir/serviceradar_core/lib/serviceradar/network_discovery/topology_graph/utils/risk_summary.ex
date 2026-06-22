defmodule ServiceRadar.NetworkDiscovery.TopologyGraph.Utils.RiskSummary do
  @moduledoc false

  alias ServiceRadar.NetworkDiscovery.TopologyGraph.Utils

  def normalize_endpoint_inventory_risk_summary(summary) do
    %{
      pkg_worst_severity:
        summary
        |> Utils.map_value(:pkg_worst_severity)
        |> normalize_risk_summary_severity(),
      pkg_critical_count:
        summary
        |> Utils.map_value(:pkg_critical_count)
        |> Utils.non_negative_integer(0),
      pkg_kev_count:
        summary
        |> Utils.map_value(:pkg_kev_count)
        |> Utils.non_negative_integer(0),
      pkg_has_unpatched_rce:
        summary
        |> Utils.map_value(:pkg_has_unpatched_rce)
        |> Utils.truthy?(),
      pkg_risk_summary_at:
        summary
        |> Utils.map_value(:pkg_risk_summary_at)
        |> normalize_risk_summary_timestamp()
    }
  end

  def normalize_risk_summary_severity(value) do
    case value |> Utils.non_blank() |> Utils.normalize_confidence_tier() do
      "critical" -> "critical"
      "high" -> "high"
      "medium" -> "medium"
      "low" -> "low"
      "none" -> "none"
      _ -> "unknown"
    end
  end

  def normalize_risk_summary_timestamp(%DateTime{} = dt) do
    dt
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  def normalize_risk_summary_timestamp(value) when is_binary(value) do
    case Utils.non_blank(value) do
      nil -> Utils.current_iso8601_second()
      timestamp -> timestamp
    end
  end

  def normalize_risk_summary_timestamp(_value), do: Utils.current_iso8601_second()
end
