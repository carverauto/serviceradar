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

      "spool_wedged" ->
        sequences = Enum.join(field(detail, :gap_sequences) || [], ", ")

        "Durable delivery is blocked by #{field(detail, :gap_count)} coverage gaps " <>
          "(first sequences: #{sequences}). Recovery coverage is required. " <> spool_health(detail)

      "spool_backpressure" ->
        "Spool admission is paused. " <> spool_health(detail)

      "spool_health_unavailable" ->
        "Spool health could not be read: #{field(detail, :health_error)}"

      "agent_upgrade_pending" ->
        "The agent runs a build from before the edge-record cutover" <>
          if(field(detail, :version), do: " (#{field(detail, :version)}).", else: ".") <>
          refused_statuses(field(detail, :refused_statuses))

      "oversized_summary" ->
        oversized_summary(detail)

      other ->
        other
    end
  end

  defp spool_health(detail) do
    age =
      if field(detail, :oldest_unresolved_age_known) == true,
        do: "#{field(detail, :oldest_unresolved_age_seconds)}s",
        else: "unknown"

    "#{field(detail, :unresolved_count)} unresolved slots; oldest age #{age}; " <>
      "#{field(detail, :bytes_used)} / #{field(detail, :budget_bytes)} bytes charged."
  end

  defp refused_statuses(counts) when is_map(counts) and map_size(counts) > 0 do
    listed =
      counts
      |> Enum.map(fn {family, count} -> {to_string(family), count} end)
      |> Enum.sort()
      |> Enum.map_join(", ", fn {family, count} -> "#{family} #{count}" end)

    " It still sends durable data on the retired status path, which the gateway does not " <>
      "store (#{listed})."
  end

  defp refused_statuses(_counts), do: ""

  defp oversized_summary(detail) do
    summaries = field(detail, :summaries) || %{}

    listed =
      summaries
      |> Enum.map(fn {service, size} -> {to_string(service), size} end)
      |> Enum.sort()
      |> Enum.map_join(", ", fn {service, size} ->
        "#{service} (#{field(size, :bytes)} bytes, limit #{field(size, :limit)})"
      end)

    "The gateway refused #{field(detail, :count)} status summaries over its size limit and does " <>
      "not store them" <>
      if(listed == "", do: ".", else: ": #{listed}.") <>
      " The agent's edge records are not affected."
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
      "oversized_summary" -> "warning"
      _ -> "error"
    end
  end

  defp field(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp field(_map, _key), do: nil
end
