defmodule ServiceRadar.AgentConfig.DependencyResolvers do
  @moduledoc """
  Resolver helpers for agent config dependency catalog entries.

  Resolvers return either a list of agent IDs affected by a resource change or
  `:all_online` when the resource change is intentionally fleet-scoped.
  """

  @type affected_agents :: [String.t()] | :all_online

  @doc """
  Resolves a single assigned agent from common `agent_id`/`agent_uid` fields.
  """
  @spec record_agent_id(map() | struct()) :: affected_agents()
  def record_agent_id(record) do
    record
    |> first_present([:agent_id, "agent_id", :agent_uid, "agent_uid"])
    |> wrap_agent_id()
  end

  @doc """
  Resolves an agent by `uid`, used by resources that are themselves agent records.
  """
  @spec record_uid(map() | struct()) :: affected_agents()
  def record_uid(record) do
    record
    |> first_present([:uid, "uid", :id, "id"])
    |> wrap_agent_id()
  end

  @doc """
  Marks the change as applying to all currently online agents.
  """
  @spec all_online(map() | struct()) :: :all_online
  def all_online(_record), do: :all_online

  defp first_present(record, keys) do
    Enum.find_value(keys, fn key ->
      case get_value(record, key) do
        value when is_binary(value) and value != "" -> value
        _ -> nil
      end
    end)
  end

  defp get_value(record, key) when is_atom(key) do
    Map.get(record, key) || safe_struct_value(record, key)
  end

  defp get_value(record, key) when is_binary(key), do: Map.get(record, key)

  defp safe_struct_value(record, key) when is_struct(record) do
    Map.get(record, key)
  end

  defp safe_struct_value(_record, _key), do: nil

  defp wrap_agent_id(agent_id) when is_binary(agent_id) and agent_id != "", do: [agent_id]
  defp wrap_agent_id(_agent_id), do: []
end
