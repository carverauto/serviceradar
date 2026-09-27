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

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Plugins.RunOverrides

  @spec supports?(map() | list(), map()) :: boolean()
  def supports?(payload, status \\ %{})

  def supports?(payload, _status) when is_map(payload) do
    acknowledged_ids(payload) != [] and is_binary(assignment_id(payload))
  end

  def supports?(_payload, _status), do: false

  @spec ingest(map() | list(), map(), keyword()) :: :ok | {:error, term()}
  def ingest(payload, status, opts \\ [])

  def ingest(payload, _status, opts) when is_map(payload) do
    case {assignment_id(payload), acknowledged_ids(payload)} do
      {assignment_id, [_ | _] = ids} when is_binary(assignment_id) ->
        actor = Keyword.get(opts, :actor, SystemActor.system(:run_override_ack_ingestor))
        RunOverrides.acknowledge(assignment_id, ids, actor: actor)

      _ ->
        :ok
    end
  end

  def ingest(_payload, _status, _opts), do: :ok

  defp acknowledged_ids(payload) do
    case Map.get(payload, "run_overrides_acknowledged") do
      ids when is_list(ids) -> Enum.filter(ids, &(is_binary(&1) and &1 != ""))
      _ -> []
    end
  end

  defp assignment_id(payload) do
    case Map.get(payload, "labels") do
      %{"assignment_id" => id} when is_binary(id) and id != "" -> id
      _ -> nil
    end
  end
end
