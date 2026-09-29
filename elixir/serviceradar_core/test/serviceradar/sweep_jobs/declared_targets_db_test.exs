defmodule ServiceRadar.SweepJobs.DeclaredTargetsDbTest do
  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.AgentConfig.Compilers.SweepCompiler
  alias ServiceRadar.AgentConfig.ConfigCache
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Repo
  alias ServiceRadar.SweepJobs.SweepGroup

  @moduletag :integration

  setup_all do
    ServiceRadar.TestSupport.start_core!()
    :ok
  end

  setup do
    actor = %{
      id: Ash.UUID.generate(),
      email: "sweep-declared-targets@example.com",
      role: :admin
    }

    # Shared target query results and recorded digests outlive a test's
    # sandbox; start every test cold.
    ConfigCache.invalidate(:sweep)

    {:ok, actor: actor, unique_id: System.unique_integer([:positive])}
  end

  test "compiling a config records its query targets and the overlap view reports them", %{
    actor: actor,
    unique_id: unique_id
  } do
    device = create_device!("declared-#{unique_id}", device_ip(unique_id), actor)

    group =
      create_group!(
        %{
          name: "Declared #{unique_id}",
          target_query: "in:devices ip:#{device.ip}",
          static_targets: ["192.0.2.0/30"]
        },
        actor
      )

    assert {:ok, _config} = SweepCompiler.compile("default", nil)

    assert recorded(group.id) == [{device.ip, device.uid}]

    assert overlap_rows(group.id) ==
             Enum.sort([
               {"declared_not_observed", device.ip, device.uid, nil},
               {"declared_not_observed", "192.0.2.0/30", nil, nil}
             ])
  end

  test "a fixed-subset group declares its targets for each assigned agent", %{
    actor: actor,
    unique_id: unique_id
  } do
    agent_a = register_agent!("declared-agent-a-#{unique_id}", actor)
    agent_b = register_agent!("declared-agent-b-#{unique_id}", actor)

    group =
      create_group!(
        %{
          name: "Subset #{unique_id}",
          static_targets: ["192.0.2.8"],
          agent_ids: [agent_a.uid, agent_b.uid]
        },
        actor
      )

    assert overlap_rows(group.id) ==
             Enum.sort([
               {"declared_not_observed", "192.0.2.8", nil, agent_a.uid},
               {"declared_not_observed", "192.0.2.8", nil, agent_b.uid}
             ])
  end

  test "an unchanged recompile leaves rows untouched; a failed query keeps them; an empty one clears them",
       %{actor: actor, unique_id: unique_id} do
    device = create_device!("kept-#{unique_id}", device_ip(unique_id), actor)

    group =
      create_group!(
        %{name: "Kept #{unique_id}", target_query: "in:devices ip:#{device.ip}"},
        actor
      )

    assert {:ok, _config} = SweepCompiler.compile("default", nil)
    [first_resolved_at] = resolved_at(group.id)

    # Drop the digest so the recompile has to compare against the table itself.
    ConfigCache.invalidate(:sweep)
    assert {:ok, _config} = SweepCompiler.compile("default", nil)
    assert resolved_at(group.id) == [first_resolved_at]

    ConfigCache.invalidate(:sweep)

    assert {:ok, _config} =
             SweepCompiler.compile("default", nil,
               query_page_fn: fn _query, _opts -> {:error, :srql_unavailable} end
             )

    assert recorded(group.id) == [{device.ip, device.uid}]

    ConfigCache.invalidate(:sweep)

    assert {:ok, _config} =
             SweepCompiler.compile("default", nil,
               query_page_fn: fn _query, _opts -> {:ok, %{rows: [], next_cursor: nil}} end
             )

    assert recorded(group.id) == []
  end

  test "a disabled group leaves the overlap view", %{actor: actor, unique_id: unique_id} do
    device = create_device!("disabled-#{unique_id}", device_ip(unique_id), actor)

    group =
      create_group!(
        %{name: "Disabled #{unique_id}", target_query: "in:devices ip:#{device.ip}"},
        actor
      )

    assert {:ok, _config} = SweepCompiler.compile("default", nil)
    refute overlap_rows(group.id) == []

    group
    |> Ash.Changeset.for_update(:disable, %{}, actor: actor)
    |> Ash.update!()

    assert overlap_rows(group.id) == []
  end

  defp device_ip(unique_id), do: "198.51.100.#{rem(unique_id, 250) + 1}"

  defp create_device!(uid, ip, actor) do
    Device
    |> Ash.Changeset.for_create(:create, %{uid: uid, ip: ip, hostname: "host01.example.com"},
      actor: actor
    )
    |> Ash.create!()
  end

  defp create_group!(attrs, actor) do
    SweepGroup
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(%{partition: "default", interval: "15m", enabled: true}, attrs),
      actor: actor
    )
    |> Ash.create!()
  end

  defp register_agent!(uid, actor) do
    Agent
    |> Ash.Changeset.for_create(:register, %{uid: uid}, actor: actor)
    |> Ash.create!()
  end

  defp recorded(sweep_group_id) do
    sweep_group_id
    |> declared_rows("target, device_uid")
    |> Enum.map(fn [target, uid] -> {target, uid} end)
  end

  defp resolved_at(sweep_group_id) do
    sweep_group_id
    |> declared_rows("resolved_at")
    |> Enum.map(fn [resolved_at] -> resolved_at end)
  end

  defp declared_rows(sweep_group_id, columns) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT #{columns}
        FROM platform.sweep_group_declared_targets
        WHERE sweep_group_id = CAST(CAST($1 AS text) AS uuid)
        ORDER BY target
        """,
        [sweep_group_id]
      )

    rows
  end

  defp overlap_rows(sweep_group_id) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT relationship, declared_target, device_uid, agent_id
        FROM platform.device_sweep_overlap
        WHERE sweep_group_id = CAST(CAST($1 AS text) AS uuid) AND declared
        """,
        [sweep_group_id]
      )

    rows |> Enum.map(&List.to_tuple/1) |> Enum.sort()
  end
end
