defmodule ServiceRadar.SNMPProfiles.TargetLimit do
  @moduledoc """
  The ceiling on how many targets one SNMP profile may give one agent.

  A profile's targets are the devices its target query selects plus its
  explicit targets. A profile over the limit is refused, never cut down to the
  limit: which devices would be dropped is not a decision the platform can
  make for an operator.

  The same count decides all three places a profile is judged: saving it
  (`ServiceRadar.SNMPProfiles.Changes.CheckTargetLimit`), compiling it for an
  agent (`ServiceRadar.AgentConfig.Compilers.SNMPCompiler`), and showing it in
  the settings UI. Counting stops one past the limit, so judging a profile
  never reads more than `limit + 1` devices.

  The limit is `ServiceRadar.Edge.PipelineSettings.snmp_max_targets/2`: the
  agent's setting, else its partition's, else the global one, else the code
  default. A compile knows the agent's partition. Saving a profile and the
  settings UI do not, so there only the agent and global settings apply.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.AgentConfig.Compilers.SNMPCompiler
  alias ServiceRadar.Edge.PipelineSettings
  alias ServiceRadar.SNMPProfiles.SNMPTarget
  alias ServiceRadar.SweepJobs.ProducerAssignments

  require Ash.Query

  @type refusal :: %{
          profile_id: term(),
          profile_name: String.t() | nil,
          agent_id: String.t() | nil,
          count: pos_integer(),
          limit: pos_integer()
        }

  @doc """
  Judges `profile` for one agent in one partition.

  `agent_id` and `partition` may be `nil`. A refusal's `count` is the number of
  targets counted before counting stopped, so `limit + 1` means "more than the
  limit". A read that fails is an error, not a refusal.
  """
  @spec check(map(), String.t() | nil, String.t() | nil) ::
          :ok | {:refused, refusal()} | {:error, term()}
  def check(profile, agent_id, partition) do
    with {:ok, limit} <- limit(agent_id, partition),
         {:ok, count} <- count_targets(profile, limit) do
      if count > limit, do: {:refused, refusal(profile, agent_id, count, limit)}, else: :ok
    end
  end

  @doc """
  The refusals `profile` earns from the agents it is pinned to, or from every
  agent when it is pinned to none. The targets are counted once, up to the
  widest of those agents' limits. A failed read refuses nothing.
  """
  @spec refusals(map()) :: [refusal()]
  def refusals(profile) do
    agents =
      case profile |> Map.get(:agent_ids) |> List.wrap() do
        [] -> [nil]
        agent_ids -> Enum.uniq(agent_ids)
      end

    limits =
      for agent_id <- agents, {:ok, limit} <- [limit(agent_id, nil)], do: {agent_id, limit}

    with [_ | _] <- limits,
         {:ok, count} <- count_targets(profile, limits |> Enum.map(&elem(&1, 1)) |> Enum.max()) do
      for {agent_id, limit} <- limits, count > limit do
        refusal(profile, agent_id, min(count, limit + 1), limit)
      end
    else
      _unreadable -> []
    end
  end

  @doc "What an operator is told about a refused profile, and what to do about it."
  @spec message(refusal()) :: String.t()
  def message(refusal) do
    agent =
      case refusal.agent_id do
        nil -> "every agent"
        agent_id -> "agent #{agent_id}"
      end

    "SNMP profile \"#{refusal.profile_name}\" selects more than #{refusal.limit} targets for " <>
      "#{agent} (counted #{refusal.count}; the limit is #{refusal.limit} targets per profile " <>
      "per agent). Narrow the target query or split the profile across agents."
  end

  defp refusal(profile, agent_id, count, limit) do
    %{
      profile_id: Map.get(profile, :id),
      profile_name: Map.get(profile, :name),
      agent_id: agent_id,
      count: count,
      limit: limit
    }
  end

  defp limit(agent_id, nil), do: PipelineSettings.snmp_max_targets(agent_id, nil)

  defp limit(agent_id, partition) when is_binary(partition) do
    case ProducerAssignments.network_scope_id_for_partition(partition) do
      {:ok, scope_id} -> PipelineSettings.snmp_max_targets(agent_id, scope_id)
      {:error, :partition_not_found} -> PipelineSettings.snmp_max_targets(agent_id, nil)
      {:error, reason} -> {:error, reason}
    end
  end

  # Explicit targets first, then the devices the target query selects, a page
  # at a time, stopping one past the limit.
  defp count_targets(profile, limit) do
    actor = SystemActor.system(:snmp_target_limit)

    with {:ok, explicit} <- count_explicit_targets(Map.get(profile, :id), actor) do
      if explicit > limit do
        {:ok, limit + 1}
      else
        profile
        |> SNMPCompiler.target_query()
        |> SNMPCompiler.reduce_target_pages(actor, explicit, fn devices, count ->
          count = count + length(devices)
          if count > limit, do: {:halt, limit + 1}, else: {:cont, count}
        end)
      end
    end
  end

  defp count_explicit_targets(nil, _actor), do: {:ok, 0}

  defp count_explicit_targets(profile_id, actor) do
    SNMPTarget
    |> Ash.Query.filter(snmp_profile_id == ^profile_id)
    |> Ash.count(actor: actor)
  end
end
