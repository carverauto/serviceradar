defmodule ServiceRadar.SweepJobs.LeaseAgents do
  @moduledoc """
  The agents a sweep group runs on, each with the partition its records are written under.

  A group with `agent_ids` runs on exactly those agents, wherever they are (an isolation scan
  may target a partition other than the agent's own). A group with an empty `agent_ids` runs
  on every agent whose device is in the group's partition. Either way an agent's records are
  written under its own partition: the partition of its device. An agent with no device, or
  whose device is deleted, has no partition core can vouch for, so it is left out.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.SweepJobs.SweepGroup

  require Ash.Query

  @type candidate :: %{agent_id: String.t(), partition: String.t()}

  @doc "The agents the group runs on, sorted by agent id."
  @spec candidates(SweepGroup.t()) :: {:ok, [candidate()]} | {:error, term()}
  def candidates(%SweepGroup{} = group) do
    query =
      case List.wrap(group.agent_ids) do
        [] -> Ash.Query.filter(Agent, device.partition == ^group.partition)
        agent_ids -> Ash.Query.filter(Agent, uid in ^agent_ids)
      end

    with {:ok, agents} <-
           query
           |> Ash.Query.filter(not is_nil(device.uid) and is_nil(device.deleted_at))
           |> Ash.Query.load(:device)
           |> Ash.read(actor: actor()) do
      {:ok,
       agents
       |> Enum.map(&%{agent_id: &1.uid, partition: &1.device.partition})
       |> Enum.sort_by(& &1.agent_id)}
    end
  end

  defp actor, do: SystemActor.system(:sweep_lease_agents)
end
