defmodule ServiceRadarAgentGateway.RetiredStatusSources do
  @moduledoc """
  Which statuses `PushStatus` and `StreamStatus` still accept, and what happens to the rest.

  Durable agent data reaches the platform only as edge records. The status RPCs carry nothing
  but ephemeral, latest-wins summaries:

    * `status` - service health heartbeats, including the `agent` capability status core
      reads add-on state from;
    * `plugin-telemetry` - plugin-engine counters.

  Every other source carried durable data before the edge-record cutover: `results` (sync,
  sweep, mapper, netprobe discovery, bumblebee, endpoint inventory, k8s endpoints, MTR traces),
  the `*-metrics` sources, `plugin-result`, `workload-identity`, `flow-attribution`,
  `otlp-relay`, and add-on (`addon:<id>`) and plugin (`plugin:<id>`) telemetry. Only an agent
  built before that release still sends them. A summary whose message exceeds
  4096 bytes is refused whole under the family `oversized_summary`, never cut, since a
  cut message says something the agent never said. The gateway does not publish or forward a
  refused status, and it does not drop it silently either: `refuse/2` counts it per agent and
  family in the agent tracker, where the edge pipeline readiness report reads it as
  `agent_upgrade_pending`, in the gateway's Prometheus metrics, and as the metric
  `agent_gateway_status_retired_source_refused_count` on `metrics.agent_gateway`
  (`RuntimeMetrics`), which outlives a gateway restart.

  A push that carried durable data is not acknowledged (`durable?/1`), even when its summaries
  were accepted: an agent built before the cutover keeps data it was not told was delivered,
  and still sends it, so the data survives until the agent is upgraded instead of being
  dropped on a false acknowledgement.
  """

  alias ServiceRadarAgentGateway.RuntimeMetrics

  require Logger

  @ephemeral_sources ["status", "plugin-telemetry"]
  @retired_sources [
    "results",
    "sysmon-metrics",
    "snmp-metrics",
    "icmp-metrics",
    "rperf-metrics",
    "mtr-metrics",
    "sweep-metrics",
    "plugin-result",
    "workload-identity",
    "flow-attribution",
    "otlp-relay"
  ]

  @max_summary_bytes 4_096

  @doc """
  The bounded family a status is refused under, or `nil` for an ephemeral summary the gateway
  still forwards: `oversized_summary` for a summary over #{@max_summary_bytes} bytes, a known
  retired source by name, `addon` or `plugin` for package telemetry, and `other` for anything
  unrecognized, so an agent-chosen string never becomes a metric label.
  """
  @spec refusal_family(Monitoring.GatewayServiceStatus.t()) :: String.t() | nil
  def refusal_family(%Monitoring.GatewayServiceStatus{source: source, message: message}) do
    case normalize(source) do
      source when source in @ephemeral_sources -> size_refusal(message)
      source when source in @retired_sources -> source
      "addon:" <> _addon_id -> "addon"
      "plugin:" <> _plugin_id -> "plugin"
      _other -> "other"
    end
  end

  @doc """
  Whether the gateway refuses `status` as durable data the sender should keep: any refusal
  except an oversized summary. A summary is latest-wins and the agent builds a new one every
  interval, so refusing one is no reason to withhold the acknowledgement of a push.
  """
  @spec durable?(Monitoring.GatewayServiceStatus.t()) :: boolean()
  def durable?(%Monitoring.GatewayServiceStatus{} = status), do: refusal_family(status) not in [nil, "oversized_summary"]

  defp size_refusal(message) when is_binary(message) and byte_size(message) > @max_summary_bytes, do: "oversized_summary"

  defp size_refusal(_message), do: nil

  @doc """
  Count the statuses the gateway refused from an agent, without publishing or forwarding them.

  Each family's count is added to the agent's tracker entry, emitted as
  `[:serviceradar, :agent_gateway, :status, :retired_source_refused]` and published through
  `RuntimeMetrics`. The first refusal the tracker records for an agent is logged; later ones
  are only counted.
  """
  @spec refuse(String.t(), [Monitoring.GatewayServiceStatus.t()]) :: :ok
  def refuse(_agent_id, []), do: :ok

  def refuse(agent_id, statuses) when is_binary(agent_id) and is_list(statuses) do
    counts = Enum.frequencies_by(statuses, &refusal_family/1)
    gateway_id = ServiceRadarAgentGateway.Config.gateway_id()

    Enum.each(counts, fn {family, count} ->
      :telemetry.execute(
        [:serviceradar, :agent_gateway, :status, :retired_source_refused],
        %{count: count},
        %{source: family, gateway_id: gateway_id}
      )
    end)

    RuntimeMetrics.report_refused_statuses(counts)

    case ServiceRadar.AgentTracker.record_refused_statuses(agent_id, counts) do
      :first ->
        Logger.warning(
          "Agent #{agent_id} sent statuses the status path refuses (#{describe(counts)}). " <>
            "Durable data reaches the platform only as edge records, and a summary is limited " <>
            "to #{@max_summary_bytes} bytes; the gateway does not publish this data. Upgrade the agent."
        )

      :repeat ->
        :ok
    end

    :ok
  end

  defp describe(counts) do
    counts
    |> Enum.sort()
    |> Enum.map_join(", ", fn {family, count} -> "#{family}: #{count}" end)
  end

  defp normalize(source) when is_binary(source), do: String.trim(source)
  defp normalize(_source), do: ""
end
