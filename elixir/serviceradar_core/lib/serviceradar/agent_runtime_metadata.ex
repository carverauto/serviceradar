defmodule ServiceRadar.AgentRuntimeMetadata do
  @moduledoc """
  Overlays live AgentTracker runtime metadata onto persisted agent records.
  """

  alias ServiceRadar.Infrastructure.Agent

  @rpc_timeout 1_000
  @task_timeout 1_500

  @runtime_metadata_fields [
    :arch,
    :deployment_type,
    :gateway_id,
    :hostname,
    :os,
    :partition,
    :source_ip
  ]

  @spec hydrate_agents([Agent.t()]) :: [Agent.t()]
  def hydrate_agents(agents) when is_list(agents) do
    runtime_by_id = runtime_by_agent_id()
    Enum.map(agents, &hydrate_agent(&1, runtime_by_id))
  end

  @spec hydrate_agent(Agent.t()) :: Agent.t()
  def hydrate_agent(%Agent{} = agent) do
    hydrate_agent(agent, runtime_by_agent_id())
  end

  def hydrate_agent(agent), do: agent

  defp hydrate_agent(%Agent{uid: agent_id} = agent, runtime_by_id) when is_binary(agent_id) do
    case Map.get(runtime_by_id, agent_id) do
      nil ->
        agent

      runtime ->
        metadata =
          agent.metadata
          |> normalize_metadata()
          |> merge_runtime_metadata(runtime)

        %{
          agent
          | metadata: metadata,
            version: prefer_runtime_value(runtime.version, agent.version)
        }
    end
  end

  defp hydrate_agent(agent, _runtime_by_id), do: agent

  defp runtime_by_agent_id do
    [Node.self() | Node.list()]
    |> Task.async_stream(
      &list_node_agents/1,
      timeout: @task_timeout,
      on_timeout: :kill_task,
      max_concurrency: 4
    )
    |> Enum.flat_map(fn
      {:ok, agents} -> agents
      _ -> []
    end)
    |> Enum.reduce(%{}, fn runtime_agent, acc ->
      case runtime_agent_id(runtime_agent) do
        nil ->
          acc

        agent_id ->
          normalized = normalize_runtime_agent(runtime_agent)
          Map.update(acc, agent_id, normalized, &prefer_runtime_agent(&1, normalized))
      end
    end)
  end

  defp list_node_agents(node) do
    case :rpc.call(node, ServiceRadar.AgentTracker, :list_agents, [], @rpc_timeout) do
      agents when is_list(agents) -> agents
      _ -> []
    end
  end

  defp runtime_agent_id(agent) do
    agent_id = Map.get(agent, :agent_id) || Map.get(agent, "agent_id")

    if is_binary(agent_id) and agent_id != "", do: agent_id
  end

  defp normalize_runtime_agent(agent) do
    %{
      agent_id: runtime_agent_id(agent),
      last_seen: runtime_field(agent, :last_seen),
      last_seen_mono: runtime_field(agent, :last_seen_mono),
      version: runtime_field(agent, :version),
      gateway_id: runtime_field(agent, :gateway_id),
      hostname: runtime_field(agent, :hostname),
      source_ip: runtime_field(agent, :source_ip),
      partition: runtime_field(agent, :partition),
      os: runtime_field(agent, :os),
      arch: runtime_field(agent, :arch),
      deployment_type: runtime_field(agent, :deployment_type)
    }
  end

  defp runtime_field(agent, key) do
    Map.get(agent, key) || Map.get(agent, Atom.to_string(key))
  end

  defp prefer_runtime_agent(existing, incoming) do
    {preferred, fallback} = preferred_runtime_pair(existing, incoming)

    Map.merge(fallback, preferred, fn _key, fallback_value, preferred_value ->
      if present_value?(preferred_value), do: preferred_value, else: fallback_value
    end)
  end

  defp preferred_runtime_pair(existing, incoming) do
    existing_ms = runtime_last_seen_ms(existing)
    incoming_ms = runtime_last_seen_ms(incoming)
    existing_mono = Map.get(existing, :last_seen_mono)
    incoming_mono = Map.get(incoming, :last_seen_mono)

    cond do
      is_integer(incoming_ms) and is_integer(existing_ms) and incoming_ms >= existing_ms ->
        {incoming, existing}

      is_integer(incoming_ms) and not is_integer(existing_ms) ->
        {incoming, existing}

      is_integer(incoming_mono) and is_integer(existing_mono) and incoming_mono >= existing_mono ->
        {incoming, existing}

      is_integer(incoming_mono) and not is_integer(existing_mono) ->
        {incoming, existing}

      true ->
        {existing, incoming}
    end
  end

  defp runtime_last_seen_ms(agent) do
    case Map.get(agent, :last_seen) do
      %DateTime{} = dt ->
        DateTime.to_unix(dt, :millisecond)

      %NaiveDateTime{} = ndt ->
        ndt |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix(:millisecond)

      ts when is_integer(ts) ->
        ts

      ts when is_binary(ts) ->
        case DateTime.from_iso8601(ts) do
          {:ok, dt, _offset} -> DateTime.to_unix(dt, :millisecond)
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp present_value?(value) when value in [nil, "", []], do: false
  defp present_value?(%{} = value), do: map_size(value) > 0
  defp present_value?(_value), do: true

  defp normalize_metadata(metadata) when is_map(metadata), do: metadata
  defp normalize_metadata(_metadata), do: %{}

  defp merge_runtime_metadata(metadata, runtime) do
    Enum.reduce(@runtime_metadata_fields, metadata, fn field, acc ->
      case prefer_runtime_value(Map.get(runtime, field), metadata_value(acc, field)) do
        nil -> acc
        value -> Map.put(acc, field, value)
      end
    end)
  end

  defp metadata_value(metadata, field) do
    Map.get(metadata, field) || Map.get(metadata, Atom.to_string(field))
  end

  defp prefer_runtime_value(runtime_value, persisted_value) do
    present_text(runtime_value) || present_text(persisted_value)
  end

  defp present_text(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp present_text(_value), do: nil
end
