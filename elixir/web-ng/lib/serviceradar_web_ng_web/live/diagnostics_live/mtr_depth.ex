defmodule ServiceRadarWebNGWeb.DiagnosticsLive.MtrDepth do
  @moduledoc """
  Presentation of an MTR trace's depth.

  A trace that reached its target is as long as the path. One that did not is
  as long as probing ran, which depends on the run's time budget and unknown-hop
  limit rather than on the network. Showing that length as "hops" is what made a
  TCP trace look longer than the ICMP trace of the same path, so unreached
  traces are described by the last hop that answered and the depth probed.
  """

  @doc "One-line description of how far a trace got."
  @spec depth_summary(map()) :: String.t()
  def depth_summary(trace) when is_map(trace) do
    total = int(trace["total_hops"])
    last = last_responding_hop(trace)
    probed = probed_hops(trace)

    cond do
      trace["target_reached"] == true -> "Reached in #{total} #{hops_word(total)}"
      legacy?(trace) -> "Not reached (#{total} #{hops_word(total)} recorded)"
      last > 0 -> "No reply past hop #{last} (#{probed} probed)"
      probed > 0 -> "No replies (#{probed} probed)"
      true -> "No probes recorded"
    end
  end

  def depth_summary(_trace), do: "No probes recorded"

  @doc "Compact hop count for tables: the path length, or `last/probed` when unreached."
  @spec hop_count_label(map()) :: String.t()
  def hop_count_label(trace) when is_map(trace) do
    if trace["target_reached"] == true or legacy?(trace) do
      Integer.to_string(int(trace["total_hops"]))
    else
      "#{last_responding_hop(trace)}/#{probed_hops(trace)}"
    end
  end

  def hop_count_label(_trace), do: "0/0"

  @doc """
  Splits hops into the rows to show and a summary of the trailing run of hops
  that never answered. Hops before the last responding hop are always shown,
  since a silent hop mid-path is information; only the tail is folded.
  """
  @spec collapse_trailing_loss([map()]) ::
          {[map()], nil | %{from: pos_integer(), to: pos_integer(), count: pos_integer()}}
  def collapse_trailing_loss(hops) when is_list(hops) do
    {tail, kept} =
      hops
      |> Enum.reverse()
      |> Enum.split_while(&silent?/1)

    case tail do
      [] ->
        {hops, nil}

      [_single] ->
        {hops, nil}

      silent ->
        numbers = silent |> Enum.map(&int(&1["hop_number"])) |> Enum.sort()
        summary = %{from: List.first(numbers), to: List.last(numbers), count: length(numbers)}

        {Enum.reverse(kept), summary}
    end
  end

  def collapse_trailing_loss(_hops), do: {[], nil}

  @doc """
  Human name for an ICMP Destination Unreachable code. ICMPv4 (type 3) and
  ICMPv6 (type 1) number their codes differently, so the trace's IP version
  selects the table.
  """
  @spec unreachable_kind(integer() | nil, integer() | nil) :: String.t() | nil
  def unreachable_kind(nil, _ip_version), do: nil
  def unreachable_kind(code, 6) when is_integer(code), do: icmpv6_kind(code)
  def unreachable_kind(code, _ip_version) when is_integer(code), do: icmpv4_kind(code)
  def unreachable_kind(_code, _ip_version), do: nil

  defp icmpv4_kind(0), do: "network unreachable"
  defp icmpv4_kind(1), do: "host unreachable"
  defp icmpv4_kind(2), do: "protocol unreachable"
  defp icmpv4_kind(3), do: "port unreachable"
  defp icmpv4_kind(4), do: "fragmentation needed"
  defp icmpv4_kind(9), do: "network administratively prohibited"
  defp icmpv4_kind(10), do: "host administratively prohibited"
  defp icmpv4_kind(13), do: "administratively prohibited"
  defp icmpv4_kind(code), do: "unreachable (code #{code})"

  defp icmpv6_kind(0), do: "no route"
  defp icmpv6_kind(1), do: "administratively prohibited"
  defp icmpv6_kind(3), do: "address unreachable"
  defp icmpv6_kind(4), do: "port unreachable"
  defp icmpv6_kind(5), do: "source address failed policy"
  defp icmpv6_kind(6), do: "reject route"
  defp icmpv6_kind(code), do: "unreachable (code #{code})"

  # Traces written before these columns existed carry neither figure; derive
  # them from the hops the same way the ingestor does for older agents.
  defp last_responding_hop(trace) do
    case trace["last_responding_hop"] do
      value when is_integer(value) -> value
      _ -> deepest(trace, &(int(&1["received"]) > 0))
    end
  end

  defp probed_hops(trace) do
    case trace["probed_hops"] do
      value when is_integer(value) -> value
      _ -> max(int(trace["total_hops"]), deepest(trace, &(int(&1["sent"]) > 0)))
    end
  end

  defp deepest(trace, counted?) do
    trace
    |> Map.get("hops", [])
    |> List.wrap()
    |> Enum.filter(&(is_map(&1) and counted?.(&1)))
    |> Enum.map(&int(&1["hop_number"]))
    |> Enum.max(fn -> 0 end)
  end

  # A row written before the depth columns existed, shown without its hops:
  # nothing better than the recorded row count is known about it.
  defp legacy?(trace) do
    not is_integer(trace["last_responding_hop"]) and List.wrap(trace["hops"]) == []
  end

  defp silent?(hop) when is_map(hop), do: int(hop["received"]) == 0 and blank?(hop["addr"])
  defp silent?(_hop), do: false

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_value), do: false

  defp hops_word(1), do: "hop"
  defp hops_word(_count), do: "hops"

  defp int(value) when is_integer(value), do: value
  defp int(_value), do: 0
end
