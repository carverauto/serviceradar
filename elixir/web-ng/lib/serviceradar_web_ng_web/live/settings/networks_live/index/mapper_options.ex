defmodule ServiceRadarWebNGWeb.Settings.NetworksLive.Index.MapperOptions do
  @moduledoc false

  def mapper_agent_options(agents, partition, current_agent_id) do
    partition = normalize_partition(partition)

    options =
      agents
      |> Enum.filter(&(agent_supports_mapper?(&1) and agent_partition_matches?(&1, partition)))
      |> Enum.sort_by(&agent_label/1)
      |> Enum.map(&{agent_label(&1), &1.uid})

    append_unknown_agent_option(options, current_agent_id)
  end

  def normalize_partition(nil), do: "default"
  def normalize_partition(""), do: "default"
  def normalize_partition(value), do: value

  def agent_supports_mapper?(agent) do
    (agent.capabilities || [])
    |> Enum.filter(&(is_binary(&1) || is_atom(&1)))
    |> Enum.map(&to_string/1)
    |> Enum.any?(&(&1 == "mapper"))
  end

  def agent_partition_matches?(agent, partition) do
    metadata = agent.metadata || %{}
    agent_partition = Map.get(metadata, "partition_id") || "default"
    agent_partition == partition
  end

  def agent_label(agent) do
    name = Map.get(agent, :name)

    if is_binary(name) and name != "" do
      "#{name} (#{agent.uid})"
    else
      agent.uid
    end
  end

  def append_unknown_agent_option(options, current_agent_id) do
    current = normalize_agent_id(current_agent_id)

    cond do
      is_nil(current) ->
        options

      Enum.any?(options, fn {_label, value} -> value == current end) ->
        options

      true ->
        options ++ [{"Unknown agent (#{current})", current}]
    end
  end

  def normalize_agent_id(nil), do: nil

  def normalize_agent_id(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  def normalize_agent_id(value), do: to_string(value)
end
