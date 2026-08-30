defmodule ServiceRadar.SweepJobs.SweepGroupAssignmentIntegrationTest do
  use ServiceRadar.DataCase, async: false

  alias Ash.Error.Invalid
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Repo
  alias ServiceRadar.SweepJobs.SweepGroup

  @moduletag :integration

  setup do
    suffix = System.unique_integer([:positive, :monotonic])
    actor = %{id: Ash.UUID.generate(), email: "operator-#{suffix}@example.test", role: :operator}

    {:ok, actor: actor, suffix: suffix}
  end

  test "an authorized operator persists all-agents and selected-agent assignments", %{
    actor: actor,
    suffix: suffix
  } do
    agent_a = register_agent("agent-a-#{suffix}", actor)
    agent_b = register_agent("agent-b-#{suffix}", actor)
    agent_c = register_agent("agent-c-#{suffix}", actor)
    agent_z = register_agent("agent-z-#{suffix}", actor)

    {:ok, all_agents} = create_group("All #{suffix}", %{agent_ids: []}, actor)

    assert %{agent_ids: [], agent_id: nil} = all_agents

    {:ok, selected} =
      create_group(
        "Selected #{suffix}",
        %{agent_ids: [agent_b.uid, agent_a.uid]},
        actor
      )

    assert %{agent_ids: agent_ids, agent_id: agent_id} = selected
    assert agent_ids == [agent_a.uid, agent_b.uid]
    assert agent_id == agent_a.uid

    assert {:ok, one_agent} = update_group(selected, %{agent_id: agent_c.uid}, actor)
    assert one_agent.agent_ids == [agent_c.uid]
    assert one_agent.agent_id == agent_c.uid

    assert {:ok, many_agents} =
             update_group(one_agent, %{agent_ids: [agent_c.uid, agent_b.uid]}, actor)

    assert many_agents.agent_ids == [agent_b.uid, agent_c.uid]
    assert many_agents.agent_id == agent_b.uid

    assert {:ok, same_first_member} =
             update_group(
               many_agents,
               %{agent_ids: [agent_z.uid, agent_b.uid, agent_c.uid]},
               actor
             )

    assert same_first_member.agent_ids == [agent_b.uid, agent_c.uid, agent_z.uid]
    assert same_first_member.agent_id == agent_b.uid

    assert {:ok, all_agents_after_update} =
             update_group(same_first_member, %{agent_ids: []}, actor)

    assert all_agents_after_update.agent_ids == []
    assert is_nil(all_agents_after_update.agent_id)
  end

  test "a legacy scalar assignment becomes a one-agent canonical assignment", %{
    actor: actor,
    suffix: suffix
  } do
    agent = register_agent("agent-legacy-#{suffix}", actor)

    assert {:ok, group} = create_group("Legacy #{suffix}", %{agent_id: agent.uid}, actor)
    assert group.agent_ids == [agent.uid]
    assert group.agent_id == agent.uid
  end

  test "an unknown newly selected agent is rejected for the authorized operator", %{
    actor: actor,
    suffix: suffix
  } do
    assert {:error, %Invalid{errors: errors}} =
             create_group("Missing #{suffix}", %{agent_ids: ["agent-missing-#{suffix}"]}, actor)

    assert Enum.any?(errors, &(&1.field == :agent_ids))
  end

  test "an unresolved legacy member survives an unrelated update", %{actor: actor, suffix: suffix} do
    known = register_agent("agent-known-#{suffix}", actor)
    {:ok, group} = create_group("Stale #{suffix}", %{agent_ids: [known.uid]}, actor)
    stale_uid = "agent-stale-#{suffix}"
    {:ok, group_id} = Ecto.UUID.dump(group.id)

    assert %{num_rows: 1} =
             Repo.query!(
               """
               UPDATE platform.sweep_groups
               SET agent_ids = $1, agent_id = $2
               WHERE id = $3::uuid
               """,
               [[stale_uid], stale_uid, group_id]
             )

    {:ok, stale_group} = Ash.get(SweepGroup, group.id, actor: actor)

    assert {:ok, updated_group} =
             stale_group
             |> Ash.Changeset.for_update(:update, %{description: "updated"}, actor: actor)
             |> Ash.update()

    assert updated_group.agent_ids == [stale_uid]
    assert updated_group.agent_id == stale_uid
    assert updated_group.description == "updated"
  end

  test "known agents are accepted regardless of current capability or liveness", %{
    actor: actor,
    suffix: suffix
  } do
    agent = register_agent("agent-offline-#{suffix}", actor)

    assert agent.capabilities == []
    assert agent.status == :connecting

    assert {:ok, group} = create_group("Offline #{suffix}", %{agent_ids: [agent.uid]}, actor)
    assert group.agent_ids == [agent.uid]
  end

  defp create_group(name, attrs, actor) do
    SweepGroup
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(%{name: name, partition: "default", interval: "15m"}, attrs),
      actor: actor
    )
    |> Ash.create()
  end

  defp register_agent(uid, actor) do
    assert {:ok, agent} =
             Agent
             |> Ash.Changeset.for_create(:register, %{uid: uid}, actor: actor)
             |> Ash.create()

    agent
  end

  defp update_group(group, attrs, actor) do
    group
    |> Ash.Changeset.for_update(:update, attrs, actor: actor)
    |> Ash.update()
  end
end
