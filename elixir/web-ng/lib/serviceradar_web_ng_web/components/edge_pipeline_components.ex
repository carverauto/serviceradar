defmodule ServiceRadarWebNGWeb.EdgePipelineComponents do
  @moduledoc """
  Renders edge pipeline conditions (`ServiceRadar.Edge.PipelineReadiness`): the reasons an
  agent is off the durable edge-record pipeline, on the agent detail page and in the
  readiness report.
  """

  use Phoenix.Component

  import ServiceRadarWebNGWeb.UIComponents, only: [ui_badge: 1]

  attr :conditions, :list, required: true

  def edge_pipeline_conditions(assigns) do
    ~H"""
    <ul class="space-y-1.5">
      <li :for={condition <- @conditions} class="flex flex-wrap items-baseline gap-2 text-sm">
        <.ui_badge variant={variant(condition)} size="xs">{reason(condition)}</.ui_badge>
        <span class="text-sr-muted">{explanation(condition)}</span>
      </li>
    </ul>
    """
  end

  @doc "The wire name of a condition's reason, as the API reports it."
  @spec reason(map()) :: String.t()
  def reason(condition), do: condition |> field(:reason) |> to_string()

  @doc "One sentence saying what keeps the agent off the pipeline, from the condition's detail."
  @spec explanation(map()) :: String.t()
  def explanation(condition) do
    detail = field(condition, :detail) || %{}

    case reason(condition) do
      "partition_not_found" ->
        "Partition #{inspect(to_string(field(detail, :partition)))} has no partition row. " <>
          "Create it to give the agent grants and leases."

      "agent_disconnected" ->
        "No core node has seen the agent recently."

      "agent_upgrade_blocked" ->
        upgrade_blocked(detail)

      "spool_unavailable" ->
        "The agent's edge-record spool could not be opened" <>
          if(field(detail, :error), do: ": #{field(detail, :error)}", else: ".")

      "agent_upgrade_pending" ->
        "The agent runs a build from before the default-on edge-record sender" <>
          if(field(detail, :version), do: " (#{field(detail, :version)}).", else: ".")

      other ->
        other
    end
  end

  defp upgrade_blocked(detail) do
    case detail |> field(:cause) |> to_string() do
      "rollout_paused" ->
        "The agent is waiting in a paused release rollout."

      "no_published_release" ->
        "No agent release is published, so the rollout has no build to deliver."

      "no_release_artifact" ->
        "Release #{field(detail, :release)} has no artifact for #{field(detail, :platform)}."

      other ->
        "The release rollout cannot upgrade the agent (#{other})."
    end
  end

  defp variant(condition) do
    case reason(condition) do
      "agent_disconnected" -> "warning"
      _ -> "error"
    end
  end

  defp field(map, key) when is_map(map), do: Map.get(map, key)
  defp field(_map, _key), do: nil
end
