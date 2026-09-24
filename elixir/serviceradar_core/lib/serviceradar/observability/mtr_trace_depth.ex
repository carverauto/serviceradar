defmodule ServiceRadar.Observability.MtrTraceDepth do
  @moduledoc """
  Depth figures for an MTR trace.

  `total_hops` counts the hop rows a trace recorded. For a trace that never
  reached its target that number reflects how long probing ran, not the path
  length, so two more figures are kept alongside it: the deepest TTL that was
  probed and the deepest hop that answered. Agents that predate these fields
  report only their hops, so both are derived from the hop list when absent.
  """

  @max_port 65_535

  @doc "Deepest TTL probed: the agent's figure, else the deepest hop that sent a probe."
  @spec probed_hops(map(), [map()]) :: non_neg_integer()
  def probed_hops(trace, hops) do
    reported_or_derived(trace, "probed_hops", hops, &positive?(&1, "sent"))
  end

  @doc "Deepest hop that answered: the agent's figure, else derived from the hops."
  @spec last_responding_hop(map(), [map()]) :: non_neg_integer()
  def last_responding_hop(trace, hops) do
    reported_or_derived(trace, "last_responding_hop", hops, &positive?(&1, "received"))
  end

  @doc "The TCP destination port of a TCP trace, or nil."
  @spec tcp_port(map()) :: pos_integer() | nil
  def tcp_port(trace) do
    port = Map.get(trace, "tcp_port")

    if Map.get(trace, "protocol") == "tcp" and is_integer(port) and port in 1..@max_port do
      port
    end
  end

  defp reported_or_derived(trace, key, hops, counted?) do
    case Map.get(trace, key) do
      value when is_integer(value) and value >= 0 -> value
      _ -> deepest_hop(hops, counted?)
    end
  end

  defp deepest_hop(hops, counted?) when is_list(hops) do
    hops
    |> Enum.filter(&(is_map(&1) and counted?.(&1)))
    |> Enum.map(&Map.get(&1, "hop_number"))
    |> Enum.filter(&is_integer/1)
    |> Enum.max(fn -> 0 end)
  end

  defp deepest_hop(_hops, _counted?), do: 0

  defp positive?(hop, key) do
    case Map.get(hop, key) do
      value when is_integer(value) -> value > 0
      _ -> false
    end
  end
end
