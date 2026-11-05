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
  built before that release still sends them. The gateway does not publish or forward such a
  status, and it does not drop it silently either: `refuse/2` counts it per agent and source
  family in the agent tracker, where the edge pipeline readiness report reads it as
  `agent_upgrade_pending`, and in the gateway's Prometheus metrics.
  """

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

  @doc "Whether a status from the agent is an ephemeral summary the gateway still forwards."
  @spec accepted?(Monitoring.GatewayServiceStatus.t()) :: boolean()
  def accepted?(%Monitoring.GatewayServiceStatus{source: source}), do: normalize(source) in @ephemeral_sources

  @doc """
  The bounded family a refused source is counted under: a known retired source by name,
  `addon` or `plugin` for package telemetry, and `other` for anything unrecognized, so an
  agent-chosen string never becomes a metric label.
  """
  @spec family(term()) :: String.t()
  def family(source) do
    case normalize(source) do
      source when source in @retired_sources -> source
      "addon:" <> _addon_id -> "addon"
      "plugin:" <> _plugin_id -> "plugin"
      _other -> "other"
    end
  end

  @doc """
  Count the statuses an agent sent on the retired path, without publishing or forwarding them.

  Each family's count is added to the agent's tracker entry and emitted as
  `[:serviceradar, :agent_gateway, :status, :retired_source_refused]`. The first refusal the
  tracker records for an agent is logged; later ones are only counted.
  """
  @spec refuse(String.t(), [Monitoring.GatewayServiceStatus.t()]) :: :ok
  def refuse(_agent_id, []), do: :ok

  def refuse(agent_id, statuses) when is_binary(agent_id) and is_list(statuses) do
    counts = Enum.frequencies_by(statuses, &family(&1.source))
    gateway_id = ServiceRadarAgentGateway.Config.gateway_id()

    Enum.each(counts, fn {family, count} ->
      :telemetry.execute(
        [:serviceradar, :agent_gateway, :status, :retired_source_refused],
        %{count: count},
        %{source: family, gateway_id: gateway_id}
      )
    end)

    case ServiceRadar.AgentTracker.record_refused_statuses(agent_id, counts) do
      :first ->
        Logger.warning(
          "Agent #{agent_id} sent durable data on the retired status path " <>
            "(#{describe(counts)}). It runs a build from before the edge-record cutover; " <>
            "the gateway does not publish this data. Upgrade the agent."
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
