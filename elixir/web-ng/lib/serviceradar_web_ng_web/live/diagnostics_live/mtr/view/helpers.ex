defmodule ServiceRadarWebNGWeb.DiagnosticsLive.Mtr.View.Helpers do
  @moduledoc false

  alias ServiceRadarWebNGWeb.DiagnosticsLive.Mtr.Config
  alias ServiceRadarWebNGWeb.DiagnosticsLive.Mtr.Params

  def agent_id(agent), do: Map.get(agent, :agent_id) || Map.get(agent, "agent_id") || ""

  def agent_label(agent) do
    id = agent_id(agent)
    partition = Map.get(agent, :partition_id) || Map.get(agent, "partition_id")

    if partition && partition != "" && partition != "default" do
      "#{id} (#{partition})"
    else
      id
    end
  end

  def pending_status_variant(:queued), do: "ghost"
  def pending_status_variant(:sent), do: "info"
  def pending_status_variant(:acknowledged), do: "info"
  def pending_status_variant(:running), do: "warning"
  def pending_status_variant(_), do: "ghost"

  def trace_status_label(trace) when is_map(trace) do
    reached? = trace["target_reached"] == true
    protocol = trace[Config.payload_protocol_key()] |> to_string() |> String.downcase()
    total_hops = trace["total_hops"] || 0

    cond do
      reached? -> "Reached"
      protocol == "tcp" and is_integer(total_hops) and total_hops > 0 -> "No Terminal Reply"
      true -> "Unreachable"
    end
  end

  def trace_status_label(_), do: "Unreachable"

  def trace_status_variant(trace) when is_map(trace) do
    case trace_status_label(trace) do
      "Reached" -> "success"
      "No Terminal Reply" -> "warning"
      _ -> "error"
    end
  end

  def trace_status_variant(_), do: "error"

  def trace_history_dashboard(traces, coverage) do
    traces = List.wrap(traces)
    trace_count = length(traces)
    reached_count = Enum.count(traces, &(&1["target_reached"] == true))
    max_hops = traces |> Enum.map(&(&1["total_hops"] || 0)) |> Enum.max(fn -> 0 end)
    reachability_trace_count = coverage_count(coverage, :trace_count, trace_count)
    reachability_reached_count = coverage_count(coverage, :reached_count, reached_count)
    agent_counts = agent_counts(traces)

    %{
      trace_count: trace_count,
      reached_count: reached_count,
      failed_count: max(trace_count - reached_count, 0),
      reachability_trace_count: reachability_trace_count,
      reachability_reached_count: reachability_reached_count,
      reachability_failed_count:
        coverage_count(coverage, :failed_count, max(reachability_trace_count - reachability_reached_count, 0)),
      success_rate: percent(reachability_reached_count, reachability_trace_count),
      agent_count: map_size(agent_counts),
      agent_mix: agent_mix(agent_counts),
      max_hops: max_hops
    }
  end

  def coverage_count(coverage, key, default) when is_map(coverage) do
    case Map.get(coverage, key) do
      value when is_integer(value) and value >= 0 -> value
      value when is_float(value) and value >= 0 -> trunc(value)
      _ -> default
    end
  end

  def coverage_count(_coverage, _key, default), do: default
  def trace_hop_width(trace, max_hops), do: pct_width(trace["total_hops"] || 0, max_hops)
  def pct_width(_value, max_value) when max_value in [0, 0.0], do: "0%"
  def pct_width(value, max_value), do: "#{Float.round(min(1.0, max(value / max_value, 0.0)) * 100, 1)}%"
  def percent(_value, total) when total in [0, 0.0], do: 0.0
  def percent(value, total), do: Float.round(value / total * 100, 1)

  def radial_value(value) when is_number(value), do: value |> round() |> min(100) |> max(0)
  def radial_value(_), do: 0

  def reachability_tone(value) when is_number(value) and value < 80, do: "is-error"
  def reachability_tone(value) when is_number(value) and value < 95, do: "is-warning"
  def reachability_tone(_), do: "is-success"

  def retention_status_label(%{status: :ok}), do: "policy synced"
  def retention_status_label(%{status: :mismatch}), do: "policy mismatch"
  def retention_status_label(%{status: :missing}), do: "policy missing"
  def retention_status_label(%{status: :degraded}), do: "status unavailable"
  def retention_status_label(_), do: "status unavailable"

  def retention_status_text_class(%{status: :ok}), do: "text-success"
  def retention_status_text_class(%{status: status}) when status in [:mismatch, :missing], do: "text-warning"
  def retention_status_text_class(%{status: :degraded}), do: "text-error"
  def retention_status_text_class(_), do: "sr-mtr-muted"

  defp agent_counts(traces) do
    traces
    |> Enum.map(&Params.normalize_text(Map.get(&1, Config.payload_agent_id_key())))
    |> Enum.reject(&(&1 == ""))
    |> Enum.frequencies()
  end

  defp agent_mix(agent_counts) do
    max_agent_count = agent_counts |> Map.values() |> Enum.max(fn -> 0 end)

    agent_counts
    |> Enum.sort_by(fn {_agent_id, count} -> -count end)
    |> Enum.take(6)
    |> Enum.map(fn {agent_id, count} ->
      %{agent_id: agent_id, count: count, width: pct_width(count, max_agent_count)}
    end)
  end
end
