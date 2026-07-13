defmodule ServiceRadar.Edge.AgentConfigAddonPrecedenceTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias ServiceRadar.Edge.AgentConfigGenerator
  alias ServiceRadar.Plugins.AddonAssignment

  test "manual assignments win over profile assignments" do
    manual = assignment(source: :manual, updated_at: ~U[2026-07-01 00:00:00.000000Z])

    profile =
      assignment(
        source: :profile,
        profile_name: "Broad profile",
        priority: 10,
        updated_at: ~U[2026-07-10 00:00:00.000000Z]
      )

    capture_log(fn ->
      assert [^manual] =
               AgentConfigGenerator.select_effective_addon_assignments([profile, manual])
    end)
  end

  test "lower profile priority wins regardless of recency" do
    high_priority =
      assignment(
        source: :profile,
        profile_name: "Targeted override",
        priority: 10,
        updated_at: ~U[2026-07-01 00:00:00.000000Z]
      )

    low_priority =
      assignment(
        source: :profile,
        profile_name: "Broad default",
        priority: 100,
        updated_at: ~U[2026-07-10 00:00:00.000000Z]
      )

    capture_log(fn ->
      assert [^high_priority] =
               AgentConfigGenerator.select_effective_addon_assignments([
                 low_priority,
                 high_priority
               ])
    end)
  end

  test "equal-priority duplicates resolve deterministically to the most recently updated" do
    older =
      assignment(
        source: :profile,
        profile_name: "Anomaly A",
        priority: 100,
        updated_at: ~U[2026-07-01 00:00:00.000000Z]
      )

    newer =
      assignment(
        source: :profile,
        profile_name: "Anomaly B",
        priority: 100,
        updated_at: ~U[2026-07-10 00:00:00.000000Z]
      )

    capture_log(fn ->
      assert [^newer] = AgentConfigGenerator.select_effective_addon_assignments([older, newer])
      assert [^newer] = AgentConfigGenerator.select_effective_addon_assignments([newer, older])
    end)
  end

  test "shadowed profile assignments warn once, then drop to debug" do
    older =
      assignment(
        source: :profile,
        profile_name: "Anomaly A",
        priority: 100,
        updated_at: ~U[2026-07-01 00:00:00.000000Z]
      )

    newer =
      assignment(
        source: :profile,
        profile_name: "Anomaly B",
        priority: 100,
        updated_at: ~U[2026-07-10 00:00:00.000000Z]
      )

    first_render =
      capture_log([level: :warning], fn ->
        AgentConfigGenerator.select_effective_addon_assignments([older, newer])
      end)

    assert first_render =~ "Duplicate enabled add-on assignments for anomaly"
    assert first_render =~ ~s|profile "Anomaly A" (assignment #{older.id})|
    assert first_render =~ ~s|is shadowed by profile "Anomaly B" (assignment #{newer.id})|

    # The generator runs on every agent poll; a persistent duplicate must not
    # repeat the warning on every render.
    second_render =
      capture_log([level: :warning], fn ->
        AgentConfigGenerator.select_effective_addon_assignments([older, newer])
      end)

    refute second_render =~ "Duplicate enabled add-on assignments"

    # A different shadowing pair still gets its own first warning.
    other = assignment(source: :profile, profile_name: "Anomaly C", priority: 100)

    other_pair =
      capture_log([level: :warning], fn ->
        AgentConfigGenerator.select_effective_addon_assignments([older, other])
      end)

    assert other_pair =~ "Duplicate enabled add-on assignments for anomaly"
  end

  test "distinct add-ons do not warn or shadow each other" do
    anomaly = assignment(source: :profile, profile_name: "Anomaly", priority: 100)

    netprobe =
      assignment(
        source: :profile,
        profile_name: "Netprobe",
        priority: 100,
        addon_id: "netprobe"
      )

    log =
      capture_log(fn ->
        effective = AgentConfigGenerator.select_effective_addon_assignments([anomaly, netprobe])

        assert Enum.sort_by(effective, & &1.addon_id) == [anomaly, netprobe]
      end)

    refute log =~ "Duplicate enabled add-on assignments"
  end

  defp assignment(opts) do
    source = Keyword.fetch!(opts, :source)

    profile_metadata =
      case Keyword.get(opts, :profile_name) do
        nil ->
          %{}

        name ->
          %{
            "profile_name" => name,
            "profile_id" => Ecto.UUID.generate(),
            "priority" => Keyword.get(opts, :priority, 100)
          }
      end

    %AddonAssignment{
      id: Ecto.UUID.generate(),
      agent_uid: "agent-1",
      addon_id: Keyword.get(opts, :addon_id, "anomaly"),
      source: source,
      enabled: true,
      profile_metadata: profile_metadata,
      updated_at: Keyword.get(opts, :updated_at, ~U[2026-07-05 00:00:00.000000Z]),
      inserted_at: ~U[2026-06-01 00:00:00.000000Z]
    }
  end
end
