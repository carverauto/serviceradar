defmodule ServiceRadar.Plugins.RunOverrideAckIngestor do
  @moduledoc """
  Plugin-result contract handler that acknowledges expired run overrides.

  After a scheduled run that received expired overrides succeeds, the agent adds
  a host-authored `run_overrides_acknowledged` list of override ids to the
  result, next to the host-authored `labels.assignment_id`. The agent replaces
  any value the plugin wrote there, so the list only names overrides the host
  actually delivered. Acknowledged overrides stop being delivered to the
  assignment (`ServiceRadar.Plugins.RunOverrides`).
  """

  @behaviour ServiceRadar.Observability.PluginResultHandler

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Observability.PluginResultHandlerOutcome
  alias ServiceRadar.Plugins.RunOverrides

  @refused_reasons [
    :missing_plugin_assignment_provenance,
    :invalid_run_overrides_acknowledged
  ]

  @impl true
  def settled_reasons, do: []

  @impl true
  def refused_reasons, do: @refused_reasons

  @impl true
  @spec supports?(map() | list(), map()) :: boolean()
  def supports?(payload, status \\ %{})

  def supports?(payload, status) when is_map(payload) do
    acknowledged_ids(payload) != [] and is_binary(resolve_assignment_id(payload, status))
  end

  def supports?(_payload, _status), do: false

  @impl true
  @spec ingest(map() | list(), map(), keyword()) :: PluginResultHandlerOutcome.t()
  def ingest(payload, status, opts \\ [])

  def ingest(payload, status, opts) when is_map(payload) do
    case Map.fetch(payload, "run_overrides_acknowledged") do
      :error ->
        :ok

      {:ok, nil} ->
        :ok

      {:ok, []} ->
        :ok

      {:ok, ids} when is_list(ids) ->
        case {resolve_assignment_id(payload, status),
              Enum.filter(ids, &(is_binary(&1) and &1 != ""))} do
          {_assignment_id, []} ->
            :ok

          {assignment_id, valid_ids} when is_binary(assignment_id) ->
            actor = Keyword.get(opts, :actor, SystemActor.system(:run_override_ack_ingestor))
            RunOverrides.acknowledge(assignment_id, valid_ids, actor: actor)

          {nil, _valid_ids} ->
            {:refused, :missing_plugin_assignment_provenance,
             %{agent_id: status_agent_id(status)}}
        end

      {:ok, _invalid} ->
        case resolve_assignment_id(payload, status) do
          nil ->
            {:refused, :missing_plugin_assignment_provenance,
             %{agent_id: status_agent_id(status)}}

          assignment_id ->
            {:refused, :invalid_run_overrides_acknowledged,
             %{agent_id: status_agent_id(status), assignment_id: assignment_id}}
        end
    end
  end

  def ingest(_payload, _status, _opts), do: :ok

  defp acknowledged_ids(payload) do
    case Map.get(payload, "run_overrides_acknowledged") do
      ids when is_list(ids) -> Enum.filter(ids, &(is_binary(&1) and &1 != ""))
      _ -> []
    end
  end

  defp resolve_assignment_id(payload, status) do
    assignment_id(payload) || provenance_assignment_id(status)
  end

  defp assignment_id(payload) do
    case Map.get(payload, "labels") do
      %{"assignment_id" => id} when is_binary(id) ->
        trimmed = String.trim(id)
        if trimmed != "", do: trimmed

      _ ->
        nil
    end
  end

  defp provenance_assignment_id(status) when is_map(status) do
    prov = Map.get(status, :plugin_provenance) || Map.get(status, "plugin_provenance")

    case prov do
      %{"assignment_id" => id} when is_binary(id) ->
        trimmed = String.trim(id)
        if trimmed != "", do: trimmed

      %{assignment_id: id} when is_binary(id) ->
        trimmed = String.trim(id)
        if trimmed != "", do: trimmed

      _ ->
        nil
    end
  end

  defp provenance_assignment_id(_status), do: nil

  defp status_agent_id(status) when is_map(status) do
    case Map.get(status, :agent_id) || Map.get(status, "agent_id") do
      value when is_binary(value) ->
        trimmed = String.trim(value)
        if trimmed != "", do: trimmed

      _ ->
        nil
    end
  end

  defp status_agent_id(_status), do: nil
end
