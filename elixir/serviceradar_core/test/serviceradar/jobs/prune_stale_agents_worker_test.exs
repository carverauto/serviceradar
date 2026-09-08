defmodule ServiceRadar.Jobs.PruneStaleAgentsWorkerTest do
  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Jobs.PruneStaleAgentsWorker
  alias ServiceRadar.Repo

  @moduletag :database

  setup_all do
    ServiceRadar.TestSupport.start_core!()
    :ok
  end

  setup do
    unique_id = :erlang.unique_integer([:positive])
    actor = SystemActor.system(:test)

    {:ok, actor: actor, unique_id: unique_id}
  end

  test "retires connected agents whose heartbeat is older than retention", %{
    actor: actor,
    unique_id: unique_id
  } do
    agent_uid = "agent-stale-prune-#{unique_id}"

    assert {:ok, _agent} =
             Agent
             |> Ash.Changeset.for_create(
               :register_connected,
               %{
                 uid: agent_uid,
                 name: "Stale Prune Agent",
                 host: "192.0.2.#{rem(unique_id, 200) + 1}",
                 port: 50_051,
                 capabilities: ["camera"]
               },
               actor: actor
             )
             |> Ash.create()

    stale_time =
      DateTime.utc_now()
      |> DateTime.add(-2, :hour)
      |> DateTime.truncate(:second)

    Repo.query!(
      "UPDATE platform.ocsf_agents SET last_seen_time = $1 WHERE uid = $2",
      [stale_time, agent_uid]
    )

    assert {:ok, connected_agents} = Agent.list_connected(actor: actor)
    refute Enum.any?(connected_agents, &(&1.uid == agent_uid))

    assert {:ok, %{retired: retired}} = PruneStaleAgentsWorker.prune(retention_hours: 1)
    assert retired >= 1

    assert {:ok, agent} = Agent.get_by_uid(agent_uid, actor: actor)
    assert agent.status == :unavailable
    assert agent.is_healthy == false
  end

  test "keeps recently seen connected agents available", %{
    actor: actor,
    unique_id: unique_id
  } do
    agent_uid = "agent-recent-prune-#{unique_id}"

    assert {:ok, _agent} =
             Agent
             |> Ash.Changeset.for_create(
               :register_connected,
               %{
                 uid: agent_uid,
                 name: "Recent Prune Agent",
                 host: "198.51.100.#{rem(unique_id, 200) + 1}",
                 port: 50_051
               },
               actor: actor
             )
             |> Ash.create()

    assert {:ok, _summary} = PruneStaleAgentsWorker.prune(retention_hours: 1)

    assert {:ok, agent} = Agent.get_by_uid(agent_uid, actor: actor)
    assert agent.status == :connected
    assert agent.is_healthy == true
  end

  test "normalizes already unavailable stale agents", %{
    actor: actor,
    unique_id: unique_id
  } do
    agent_uid = "agent-unavailable-prune-#{unique_id}"

    assert {:ok, agent} =
             Agent
             |> Ash.Changeset.for_create(
               :register_connected,
               %{
                 uid: agent_uid,
                 name: "Unavailable Prune Agent",
                 host: "203.0.113.#{rem(unique_id, 200) + 1}",
                 port: 50_051,
                 capabilities: ["camera"]
               },
               actor: actor
             )
             |> Ash.create()

    assert {:ok, _agent} =
             agent
             |> Ash.Changeset.for_update(:mark_unavailable, %{reason: "test"}, actor: actor)
             |> Ash.update()

    stale_time =
      DateTime.utc_now()
      |> DateTime.add(-2, :hour)
      |> DateTime.truncate(:second)

    Repo.query!(
      "UPDATE platform.ocsf_agents SET last_seen_time = $1 WHERE uid = $2",
      [stale_time, agent_uid]
    )

    assert {:ok, %{retired: retired}} = PruneStaleAgentsWorker.prune(retention_hours: 1)
    assert retired >= 1

    assert {:ok, agent} = Agent.get_by_uid(agent_uid, actor: actor)
    assert agent.status == :unavailable
    assert agent.is_healthy == false
  end
end
