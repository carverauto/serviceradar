defmodule ServiceRadar.Observability.MtrTcpHandshake do
  @moduledoc """
  Storage mapping for an MTR trace's TCP handshake diagnostics and per-hop
  reply counters.

  A crafted-SYN TCP trace ends with a destination handshake phase and reports
  it as a `tcp_handshake` object. ICMP and UDP traces, connect-fallback TCP
  traces and agents that predate the phase carry no such object, and every
  handshake column is stored as nil for them rather than zero, so "not
  measured" never reads as "no SYN-ACKs".

  Hops report reply counters by kind with zero values omitted, so a missing
  key is a zero only when the agent reports counters at all. A trace is taken
  to report them when any of its hops carries one; otherwise the counters are
  stored as nil.
  """

  @handshake_integers [
    tcp_handshake_ttl: "ttl",
    tcp_handshake_attempts: "attempts",
    tcp_syn_sent: "syn_sent",
    tcp_synack_received: "synack_received",
    tcp_rst_received: "rst_received",
    tcp_syn_unanswered: "unanswered",
    tcp_syn_retransmits: "syn_retransmits",
    tcp_answered_after_retx: "answered_after_retx",
    tcp_ack_mismatch: "ack_mismatch",
    tcp_synack_duplicates: "synack_duplicates",
    tcp_handshake_rtt_min_us: "rtt_min_us",
    tcp_handshake_rtt_avg_us: "rtt_avg_us",
    tcp_handshake_rtt_max_us: "rtt_max_us",
    tcp_server_response_us: "server_response_us"
  ]

  # The engine omits zero RTTs, since an attempt set with no answers has no
  # RTT; those stay nil. The server response estimate is nil when either side
  # of it is missing.
  @nil_when_absent [
    :tcp_handshake_rtt_min_us,
    :tcp_handshake_rtt_avg_us,
    :tcp_handshake_rtt_max_us,
    :tcp_server_response_us
  ]

  @hop_counters [
    reply_time_exceeded: "reply_time_exceeded",
    reply_unreachable: "reply_unreachable",
    reply_synack: "reply_synack",
    reply_rst: "reply_rst"
  ]

  @doc "Trace columns for the handshake phase; all nil when the trace has none."
  @spec trace_fields(map()) :: %{atom() => number() | nil}
  def trace_fields(trace) when is_map(trace) do
    case Map.get(trace, "tcp_handshake") do
      %{} = handshake -> handshake_fields(handshake)
      _ -> empty_trace_fields()
    end
  end

  def trace_fields(_trace), do: empty_trace_fields()

  @doc "Column names this module writes on `mtr_traces`."
  @spec trace_columns() :: [atom()]
  def trace_columns, do: [:tcp_syn_drop_pct | Keyword.keys(@handshake_integers)]

  @doc "Whether any hop of the trace reports a reply counter."
  @spec reply_counters_reported?([map()]) :: boolean()
  def reply_counters_reported?(hops) when is_list(hops) do
    Enum.any?(hops, fn hop ->
      is_map(hop) and Enum.any?(@hop_counters, fn {_column, key} -> Map.has_key?(hop, key) end)
    end)
  end

  def reply_counters_reported?(_hops), do: false

  @doc """
  Hop columns for the reply counters. `reported?` is
  `reply_counters_reported?/1` for the hop's trace.
  """
  @spec hop_fields(map(), boolean()) :: %{atom() => non_neg_integer() | nil}
  def hop_fields(hop, reported?) when is_map(hop) do
    Map.new(@hop_counters, fn {column, key} ->
      {column, hop_counter(Map.get(hop, key), reported?)}
    end)
  end

  defp handshake_fields(handshake) do
    integers =
      Map.new(@handshake_integers, fn {column, key} ->
        {column, handshake_integer(column, Map.get(handshake, key))}
      end)

    Map.put(integers, :tcp_syn_drop_pct, float(Map.get(handshake, "syn_drop_pct")))
  end

  defp handshake_integer(column, value) do
    case integer(value) do
      nil -> if column in @nil_when_absent, do: nil, else: 0
      number -> number
    end
  end

  defp hop_counter(value, reported?) do
    case integer(value) do
      nil -> if reported?, do: 0
      number -> number
    end
  end

  defp empty_trace_fields, do: Map.new(trace_columns(), &{&1, nil})

  defp integer(value) when is_integer(value) and value >= 0, do: value
  defp integer(_value), do: nil

  defp float(value) when is_float(value) and value >= 0, do: value
  defp float(value) when is_integer(value) and value >= 0, do: value / 1
  defp float(_value), do: 0.0
end
