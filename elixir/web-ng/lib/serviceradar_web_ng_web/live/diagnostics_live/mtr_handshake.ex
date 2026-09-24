defmodule ServiceRadarWebNGWeb.DiagnosticsLive.MtrHandshake do
  @moduledoc """
  TCP handshake diagnostics of an MTR trace, and per-hop reply counters.

  The figures come from an active SYN probe, not a passively observed flow, so
  each one carries its definition as a tooltip. A TCP trace without handshake
  figures came from an agent that could not craft SYNs (it fell back to
  connect()) or predates the handshake phase; the panel says so instead of
  showing zeros.
  """
  use Phoenix.Component

  @definitions %{
    syn_sent: "Destination-phase SYNs sent, including retransmissions",
    synack: "Handshake attempts the target answered with SYN-ACK",
    rst: "Handshake attempts the target answered with RST or RST+ACK (port closed or rejected)",
    drop:
      "Handshakes that never got an answer, as a share of handshakes attempted (first SYN plus retries is one attempt)",
    retx:
      "SYNs re-sent after the per-probe timeout, and attempts that succeeded only on a retry (loss on the first try)",
    anomalies:
      "Replies whose acknowledgement matches no SYN we sent (sequence rewriting, a SYN proxy or a middlebox), and repeated SYN-ACKs for one attempt (return-path loss)",
    rtt: "SYN to SYN-ACK/RST time at the destination: minimum / average / maximum",
    server:
      "Estimated time spent in the target rather than on the path: handshake RTT average minus the RTT average of the last transit hop, floored at zero"
  }

  @doc "Tooltip text for a handshake figure."
  @spec definition(atom()) :: String.t()
  def definition(key), do: Map.fetch!(@definitions, key)

  @doc "Whether the trace carries handshake figures."
  @spec measured?(map()) :: boolean()
  def measured?(trace) when is_map(trace), do: is_integer(trace["tcp_syn_sent"])
  def measured?(_trace), do: false

  @doc """
  Reply counters of a hop as a short label, e.g. "3 TE" or "2 SYN-ACK, 1 RST";
  "-" when the hop has no counters.
  """
  @spec reply_summary(map()) :: String.t()
  def reply_summary(hop) when is_map(hop) do
    [
      {hop["reply_time_exceeded"], "TE"},
      {hop["reply_unreachable"], "Unreach"},
      {hop["reply_synack"], "SYN-ACK"},
      {hop["reply_rst"], "RST"}
    ]
    |> Enum.filter(fn {count, _label} -> is_integer(count) and count > 0 end)
    |> Enum.map_join(", ", fn {count, label} -> "#{count} #{label}" end)
    |> case do
      "" -> "-"
      summary -> summary
    end
  end

  def reply_summary(_hop), do: "-"

  @doc "The handshake panel; renders nothing for non-TCP traces."
  attr :trace, :map, required: true
  attr :id, :string, default: "mtr-tcp-handshake"

  def handshake_panel(assigns) do
    ~H"""
    <div :if={tcp?(@trace)} id={@id} class="space-y-2">
      <h3 class="text-sm font-semibold">TCP Handshake</h3>
      <p :if={not measured?(@trace)} id={"#{@id}-unavailable"} class="text-sm text-sr-muted">
        Handshake diagnostics unavailable for this trace: the agent did not run the
        SYN handshake phase (it cannot craft raw TCP segments, or predates it).
      </p>
      <div :if={measured?(@trace)} class="grid grid-cols-2 gap-3 text-sm md:grid-cols-4">
        <.figure label="SYN sent" title={definition(:syn_sent)} value={@trace["tcp_syn_sent"]} />
        <.figure label="SYN-ACK" title={definition(:synack)} value={@trace["tcp_synack_received"]} />
        <.figure label="RST" title={definition(:rst)} value={@trace["tcp_rst_received"]} />
        <.figure
          label="SYN drop"
          title={definition(:drop)}
          value={"#{format_pct(@trace["tcp_syn_drop_pct"])} (#{@trace["tcp_syn_unanswered"] || 0}/#{@trace["tcp_handshake_attempts"] || 0})"}
        />
        <.figure
          label="Retx"
          title={definition(:retx)}
          value={"#{@trace["tcp_syn_retransmits"] || 0} sent, #{@trace["tcp_answered_after_retx"] || 0} answered after"}
        />
        <.figure
          label="Ack anomalies"
          title={definition(:anomalies)}
          value={"#{@trace["tcp_ack_mismatch"] || 0} mismatch, #{@trace["tcp_synack_duplicates"] || 0} dup"}
        />
        <.figure
          label="Handshake RTT"
          title={definition(:rtt)}
          value={"#{format_us(@trace["tcp_handshake_rtt_min_us"])} / #{format_us(@trace["tcp_handshake_rtt_avg_us"])} / #{format_us(@trace["tcp_handshake_rtt_max_us"])}"}
        />
        <.figure
          label="Server response"
          title={definition(:server)}
          value={format_us(@trace["tcp_server_response_us"])}
        />
      </div>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :title, :string, required: true
  attr :value, :any, required: true

  defp figure(assigns) do
    ~H"""
    <div title={@title} class="cursor-help">
      <div class="text-xs text-sr-muted">{@label}</div>
      <div class="font-mono">{@value}</div>
    </div>
    """
  end

  defp tcp?(trace) when is_map(trace), do: trace["protocol"] == "tcp"
  defp tcp?(_trace), do: false

  @doc false
  def format_us(us) when is_integer(us) and us >= 1_000, do: "#{Float.round(us / 1_000, 1)}ms"
  def format_us(us) when is_integer(us) and us >= 0, do: "#{us}us"
  def format_us(_us), do: "-"

  defp format_pct(pct) when is_float(pct), do: "#{Float.round(pct, 1)}%"
  defp format_pct(pct) when is_integer(pct), do: "#{pct}%"
  defp format_pct(_pct), do: "-"
end
