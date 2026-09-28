defmodule ServiceRadar.SweepJobs.ProducerAssignmentsDbTest do
  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.SweepJobs.ProducerAssignments
  alias ServiceRadar.SweepJobs.SweepGroup

  @moduletag :integration

  setup do
    suffix = System.unique_integer([:positive, :monotonic])
    actor = %{id: Ash.UUID.generate(), email: "operator-#{suffix}@example.test", role: :operator}

    {:ok, actor: actor, suffix: suffix}
  end

  test "ensure creates an active assignment at epoch 1 and returns it unchanged afterwards",
       ctx do
    group = create_group!(ctx)
    scope = Ash.UUID.generate()

    assert {:ok, created} = ProducerAssignments.ensure(group.id, "agent-a", scope)
    assert %{state: :active, authority_epoch: 1, run_shard: 0, network_scope_id: ^scope} = created

    assert {:ok, again} = ProducerAssignments.ensure(group.id, "agent-a", scope)
    assert again.id == created.id
    assert again.authority_epoch == 1
  end

  test "bump_group moves only the active assignments of its own group", ctx do
    group = create_group!(ctx)
    other = create_group!(ctx)
    scope = Ash.UUID.generate()

    {:ok, a} = ProducerAssignments.ensure(group.id, "agent-a", scope)
    {:ok, b} = ProducerAssignments.ensure(group.id, "agent-b", scope)
    {:ok, elsewhere} = ProducerAssignments.ensure(other.id, "agent-a", scope)
    {:ok, 1} = ProducerAssignments.revoke_agents(group.id, ["agent-b"])

    assert {:ok, 1} = ProducerAssignments.bump_group(group.id)

    assert epoch(group.id, "agent-a") == a.authority_epoch + 1
    assert epoch(group.id, "agent-b") == b.authority_epoch + 1
    assert epoch(other.id, "agent-a") == elsewhere.authority_epoch
  end

  test "revoking fences the assignment and ensure reissues it under a higher epoch", ctx do
    group = create_group!(ctx)
    scope = Ash.UUID.generate()
    {:ok, created} = ProducerAssignments.ensure(group.id, "agent-a", scope)

    assert {:ok, 1} = ProducerAssignments.revoke_agents(group.id, ["agent-a"])

    assert {:ok, %{state: :revoked, authority_epoch: 2, revoked_at: %DateTime{}}} =
             get(group, "agent-a")

    # A revoked assignment is not revoked twice.
    assert {:ok, 0} = ProducerAssignments.revoke_agents(group.id, ["agent-a"])

    assert {:ok, reissued} = ProducerAssignments.ensure(group.id, "agent-a", scope)
    assert reissued.id == created.id
    assert %{state: :active, authority_epoch: 3, revoked_at: nil} = reissued
  end

  test "an active assignment whose scope changed is reissued under a new epoch", ctx do
    group = create_group!(ctx)
    old_scope = Ash.UUID.generate()
    new_scope = Ash.UUID.generate()
    {:ok, created} = ProducerAssignments.ensure(group.id, "agent-a", old_scope)

    assert {:ok, moved} = ProducerAssignments.ensure(group.id, "agent-a", new_scope)
    assert moved.id == created.id
    assert %{state: :active, authority_epoch: 2, network_scope_id: ^new_scope} = moved
  end

  test "a change to a group's targets fences its assignments and a rename does not", ctx do
    group = create_group!(ctx)
    {:ok, _} = ProducerAssignments.ensure(group.id, "agent-a", Ash.UUID.generate())

    {:ok, group} = update_group(group, :update, %{description: "renamed"}, ctx.actor)
    assert epoch(group.id, "agent-a") == 1

    {:ok, group} =
      update_group(group, :add_targets, %{targets: ["192.0.2.0/24"]}, ctx.actor)

    assert epoch(group.id, "agent-a") == 2

    {:ok, _group} =
      update_group(group, :remove_targets, %{targets: ["192.0.2.0/24"]}, ctx.actor)

    assert epoch(group.id, "agent-a") == 3
  end

  test "selecting an explicit agent set revokes the assignments of other agents", ctx do
    group = create_group!(ctx)
    keep = register_agent!("agent-keep-#{ctx.suffix}", ctx.actor)
    drop = "agent-drop-#{ctx.suffix}"
    scope = Ash.UUID.generate()

    {:ok, _} = ProducerAssignments.ensure(group.id, keep.uid, scope)
    {:ok, _} = ProducerAssignments.ensure(group.id, drop, scope)

    assert {:ok, _group} = update_group(group, :update, %{agent_ids: [keep.uid]}, ctx.actor)

    assert {:ok, %{state: :active, authority_epoch: 2}} = get(group, keep.uid)
    assert {:ok, %{state: :revoked, authority_epoch: 2}} = get(group, drop)
  end

  test "a partition that does not exist has no network scope", ctx do
    assert {:error, :partition_not_found} =
             ProducerAssignments.network_scope_id_for_partition("no-such-partition-#{ctx.suffix}")
  end

  defp create_group!(%{actor: actor, suffix: suffix}) do
    unique = System.unique_integer([:positive, :monotonic])

    # Disabled, so creating it schedules no Oban worker and the test can run async.
    assert {:ok, group} =
             SweepGroup
             |> Ash.Changeset.for_create(
               :create,
               %{
                 name: "Producer assignments #{suffix}-#{unique}",
                 partition: "default",
                 interval: "15m",
                 enabled: false,
                 agent_ids: []
               },
               actor: actor
             )
             |> Ash.create()

    group
  end

  defp update_group(group, action, attrs, actor) do
    group
    |> Ash.Changeset.for_update(action, attrs, actor: actor)
    |> Ash.update()
  end

  defp register_agent!(uid, actor) do
    assert {:ok, agent} =
             Agent
             |> Ash.Changeset.for_create(:register, %{uid: uid}, actor: actor)
             |> Ash.create()

    agent
  end

  defp get(group, agent_id), do: ProducerAssignments.get(group.id, agent_id)

  defp epoch(group_id, agent_id) do
    assert {:ok, %{authority_epoch: epoch}} = ProducerAssignments.get(group_id, agent_id)
    epoch
  end
end
