defmodule ServiceRadar.Edge.PipelineReadiness do
  @moduledoc """
  Why an agent would be off the durable edge-record pipeline: the read-only edge pipeline
  readiness report, and the per-agent edge pipeline conditions it is built from.

  Every condition is derived on read from state core already holds. Nothing here writes, and
  nothing here changes an agent, grant, lease or data path. A ready agent has no condition.

    * `:partition_not_found` - the agent's partition has no partition row, so core issues it
      no standing grant and leases it no sweep. The partition is the authenticated one the
      gateway recorded on the agent (`metadata.partition_id`), else the one its live check-in
      reports, else its device's, else `"default"` (a check-in with no partition is in
      `"default"`). Core never creates a partition from an agent's claim, so the condition
      clears when an operator creates that partition. Detail: `partition`.
    * `:agent_disconnected` - no connected core node's agent tracker has seen the agent within
      the tracker's stale window.
    * `:agent_upgrade_blocked` - the agent release rollout cannot deliver a new agent build to
      the agent. Detail `cause`:
        * `:rollout_paused` - the agent is an unfinished target of a paused rollout;
        * `:no_published_release` - no agent release is published;
        * `:no_release_artifact` - the newest published release (detail `release`) carries no
          enabled artifact for the agent's platform (detail `platform`).

      An agent that runs from a container image (Kubernetes, Docker or another container
      runtime) is upgraded with its image, not by the release rollout, so it is never blocked
      here. A disconnected agent's platform is not known, so it is reported only as
      `:agent_disconnected`.

    * `:spool_unavailable` - the agent reported that its edge-record spool could not be
      opened, so it has nowhere to put edge records. Detail: `error`.
    * `:agent_upgrade_pending` - the agent runs a build from before the default-on edge-record
      sender: its last check-in carried no spool status. Detail: `version`.

  The last two come from the agent's last check-in (`metadata.edge_record_spool`, which the
  gateway records from the hello), so they are reported for connected agents only.

  Superseded agent identities are left out: they have been replaced and produce nothing.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.AgentRuntimeMetadata
  alias ServiceRadar.Edge.AgentRelease
  alias ServiceRadar.Edge.AgentReleaseManager
  alias ServiceRadar.Edge.AgentReleaseTarget
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Infrastructure.Partition

  require Ash.Query

  @default_partition "default"
  # Deployment types the agent reports (`go/pkg/agent/push_loop_deployment.go`) whose binary
  # comes from an image rather than a package the release rollout replaces.
  @image_deployment_types ~w(kubernetes docker container)
  @finished_target_statuses [:healthy, :failed, :rolled_back, :canceled]

  @type reason ::
          :partition_not_found
          | :agent_disconnected
          | :agent_upgrade_blocked
          | :spool_unavailable
          | :agent_upgrade_pending
  @type condition :: %{reason: reason(), detail: map()}
  @type entry :: %{
          agent_id: String.t(),
          name: String.t() | nil,
          partition: String.t(),
          conditions: [condition(), ...]
        }
  @type facts :: %{
          partitions: MapSet.t(String.t()),
          runtime: %{String.t() => map()},
          release: AgentRelease.t() | nil,
          paused_agent_ids: MapSet.t(String.t())
        }

  @doc """
  The readiness report: every agent with at least one condition, sorted by agent id. An empty
  list means every agent is ready.
  """
  @spec report() :: {:ok, [entry()]} | {:error, term()}
  def report do
    with {:ok, agents} <- read_agents(),
         {:ok, facts} <- facts() do
      {:ok,
       agents
       |> Enum.map(&entry(&1, facts))
       |> Enum.reject(&(&1.conditions == []))
       |> Enum.sort_by(& &1.agent_id)}
    end
  end

  @doc """
  The installation state the conditions are evaluated against: partition slugs, the live
  agent tracker entries of every connected core node, the newest published agent release and
  the agents waiting in a paused rollout. An unreadable node tracker is
  `{:error, :agent_tracker_unavailable}`, not an agent reported as disconnected.
  """
  @spec facts() :: {:ok, facts()} | {:error, term()}
  def facts do
    with {:ok, partitions} <- Ash.read(Partition, actor: actor()),
         {:ok, release} <- newest_release(),
         {:ok, paused} <- paused_agent_ids(),
         {:ok, runtime} <- AgentRuntimeMetadata.runtime_agents() do
      {:ok,
       %{
         partitions: MapSet.new(partitions, & &1.slug),
         runtime: runtime,
         release: release,
         paused_agent_ids: paused
       }}
    end
  end

  @doc """
  The conditions of one agent under `facts`. The agent's `device` is read for its partition
  when it is loaded.
  """
  @spec conditions(Agent.t(), facts()) :: [condition()]
  def conditions(%Agent{status: :superseded}, _facts), do: []

  def conditions(%Agent{} = agent, facts) do
    runtime = live_runtime(Map.get(facts.runtime, agent.uid))

    partition_conditions(partition(agent, runtime), facts) ++
      connection_conditions(agent, runtime, facts)
  end

  @doc "The partition slug an agent's records are written under (see the moduledoc)."
  @spec partition(Agent.t(), map() | nil) :: String.t()
  def partition(%Agent{} = agent, runtime) do
    recorded_partition(agent) || present(runtime && runtime[:partition]) ||
      device_partition(agent) || @default_partition
  end

  defp entry(agent, facts) do
    runtime = live_runtime(Map.get(facts.runtime, agent.uid))

    %{
      agent_id: agent.uid,
      name: agent.name,
      partition: partition(agent, runtime),
      conditions: conditions(agent, facts)
    }
  end

  defp partition_conditions(partition, facts) do
    if MapSet.member?(facts.partitions, partition) do
      []
    else
      [%{reason: :partition_not_found, detail: %{partition: partition}}]
    end
  end

  defp connection_conditions(_agent, nil, _facts),
    do: [%{reason: :agent_disconnected, detail: %{}}]

  defp connection_conditions(agent, runtime, facts) do
    spool_conditions(agent) ++
      if present(runtime[:deployment_type]) in @image_deployment_types do
        []
      else
        upgrade_conditions(agent, runtime, facts)
      end
  end

  defp spool_conditions(agent) do
    case recorded_spool(agent) do
      nil -> [%{reason: :agent_upgrade_pending, detail: %{version: agent.version}}]
      spool -> spool_status_conditions(spool)
    end
  end

  # The gateway's map, with atom keys until the row is read back from jsonb.
  defp recorded_spool(%Agent{metadata: %{} = metadata}) do
    case Map.get(metadata, "edge_record_spool") || Map.get(metadata, :edge_record_spool) do
      %{} = spool -> spool
      _ -> nil
    end
  end

  defp recorded_spool(_agent), do: nil

  defp spool_status_conditions(spool) do
    if (Map.get(spool, "available") || Map.get(spool, :available)) == true do
      []
    else
      error = Map.get(spool, "error") || Map.get(spool, :error)
      [%{reason: :spool_unavailable, detail: %{error: present(error)}}]
    end
  end

  defp upgrade_conditions(agent, runtime, facts) do
    cond do
      MapSet.member?(facts.paused_agent_ids, agent.uid) ->
        [blocked(%{cause: :rollout_paused})]

      is_nil(facts.release) ->
        [blocked(%{cause: :no_published_release})]

      true ->
        artifact_conditions(facts.release, present(runtime[:os]), present(runtime[:arch]))
    end
  end

  defp artifact_conditions(release, os, arch) do
    case AgentReleaseManager.artifact_for_platform(release, os, arch) do
      {:ok, _artifact} ->
        []

      {:error, {:no_matching_release_artifact, _os, _arch}} ->
        [
          blocked(%{
            cause: :no_release_artifact,
            release: release.version,
            platform: "#{os || "unknown-os"}/#{arch || "unknown-arch"}"
          })
        ]
    end
  end

  defp blocked(detail), do: %{reason: :agent_upgrade_blocked, detail: detail}

  defp live_runtime(%{active: true} = runtime), do: runtime
  defp live_runtime(_runtime), do: nil

  defp recorded_partition(%Agent{metadata: %{} = metadata}) do
    present(Map.get(metadata, "partition_id") || Map.get(metadata, :partition_id))
  end

  defp recorded_partition(_agent), do: nil

  defp device_partition(%Agent{device: %{partition: partition}}), do: present(partition)
  defp device_partition(_agent), do: nil

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present(_value), do: nil

  defp read_agents do
    Agent
    |> Ash.Query.filter(status != :superseded)
    |> Ash.Query.load(:device)
    |> Ash.read(actor: actor())
  end

  defp newest_release do
    AgentRelease
    |> Ash.Query.sort(published_at: :desc, inserted_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read_one(actor: actor())
  end

  defp paused_agent_ids do
    AgentReleaseTarget
    |> Ash.Query.filter(rollout.status == :paused and status not in ^@finished_target_statuses)
    |> Ash.Query.select([:agent_id])
    |> Ash.read(actor: actor())
    |> case do
      {:ok, targets} -> {:ok, MapSet.new(targets, & &1.agent_id)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp actor, do: SystemActor.system(:edge_pipeline_readiness)
end
