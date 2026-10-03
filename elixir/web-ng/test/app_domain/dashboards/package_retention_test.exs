defmodule ServiceRadarWebNG.Dashboards.PackageRetentionTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Dashboards.DashboardPackage
  alias ServiceRadarWebNG.Dashboards.PackageRetention

  @moduletag :db_free

  describe "build_plan/3" do
    test "enabled packages are always protected regardless of retention count" do
      old_enabled = pkg("dash-1", "v1", :enabled, ~U[2020-01-01 00:00:00Z])
      newer_disabled = pkg("dash-1", "v2", :disabled, ~U[2025-01-01 00:00:00Z])

      plan = PackageRetention.build_plan([old_enabled, newer_disabled], MapSet.new(), 1)

      assert_protected(plan, old_enabled.id, :enabled_package)
      assert_protected(plan, newer_disabled.id, :within_retention_window)
      assert plan.eligible == []
    end

    test "packages referenced by a DashboardInstance are always protected" do
      instanced = pkg("dash-1", "v1", :disabled, ~U[2020-01-01 00:00:00Z])
      older = pkg("dash-1", "v2", :disabled, ~U[2019-01-01 00:00:00Z])
      instanced_ids = MapSet.new([instanced.id])

      plan = PackageRetention.build_plan([instanced, older], instanced_ids, 1)

      assert_protected(plan, instanced.id, :has_instance)
    end

    test "keeps the N most recent versions within the retention window" do
      v3 = pkg("dash-1", "v3", :disabled, ~U[2025-01-01 00:00:00Z])
      v2 = pkg("dash-1", "v2", :disabled, ~U[2024-01-01 00:00:00Z])
      v1 = pkg("dash-1", "v1", :disabled, ~U[2023-01-01 00:00:00Z])

      plan = PackageRetention.build_plan([v1, v2, v3], MapSet.new(), 2)

      assert_protected(plan, v3.id, :within_retention_window)
      assert_protected(plan, v2.id, :within_retention_window)
      assert_eligible(plan, v1.id, :exceeds_retention_count)
    end

    test "at least one version is kept even when keep_versions is 1 and all are disabled" do
      v2 = pkg("dash-1", "v2", :disabled, ~U[2025-01-01 00:00:00Z])
      v1 = pkg("dash-1", "v1", :disabled, ~U[2024-01-01 00:00:00Z])

      plan = PackageRetention.build_plan([v1, v2], MapSet.new(), 1)

      assert_protected(plan, v2.id, :within_retention_window)
      assert_eligible(plan, v1.id, :exceeds_retention_count)
    end

    test "retention is grouped per dashboard_id independently" do
      dash1_v2 = pkg("dash-1", "v2", :disabled, ~U[2025-01-01 00:00:00Z])
      dash1_v1 = pkg("dash-1", "v1", :disabled, ~U[2024-01-01 00:00:00Z])
      dash2_v2 = pkg("dash-2", "v2", :disabled, ~U[2025-01-01 00:00:00Z])
      dash2_v1 = pkg("dash-2", "v1", :disabled, ~U[2024-01-01 00:00:00Z])

      plan =
        PackageRetention.build_plan(
          [dash1_v1, dash1_v2, dash2_v1, dash2_v2],
          MapSet.new(),
          1
        )

      assert_protected(plan, dash1_v2.id, :within_retention_window)
      assert_eligible(plan, dash1_v1.id, :exceeds_retention_count)
      assert_protected(plan, dash2_v2.id, :within_retention_window)
      assert_eligible(plan, dash2_v1.id, :exceeds_retention_count)
    end

    test "all packages protected when count does not exceed keep_versions" do
      v1 = pkg("dash-1", "v1", :disabled, ~U[2024-01-01 00:00:00Z])
      v2 = pkg("dash-1", "v2", :disabled, ~U[2025-01-01 00:00:00Z])

      plan = PackageRetention.build_plan([v1, v2], MapSet.new(), 5)

      assert plan.eligible == []
      assert length(plan.protected) == 2
    end

    test "plan all count equals sum of protected and eligible" do
      packages = Enum.map(1..4, &pkg("dash-1", "v#{&1}", :disabled, date_for(&1)))

      plan = PackageRetention.build_plan(packages, MapSet.new(), 2)

      assert length(plan.all) == 4
      assert length(plan.protected) + length(plan.eligible) == length(plan.all)
    end

    test "empty package list returns empty plan" do
      plan = PackageRetention.build_plan([], MapSet.new(), 2)

      assert plan.all == []
      assert plan.protected == []
      assert plan.eligible == []
    end
  end

  defp pkg(dashboard_id, version, status, inserted_at) do
    %DashboardPackage{
      id: "#{dashboard_id}-#{version}",
      dashboard_id: dashboard_id,
      version: version,
      status: status,
      wasm_object_key: "dashboards/#{dashboard_id}/#{version}/main.wasm",
      inserted_at: inserted_at,
      updated_at: inserted_at
    }
  end

  defp date_for(n), do: ~N[2020-01-01 00:00:00] |> DateTime.from_naive!("Etc/UTC") |> DateTime.add(n * 86_400)

  defp assert_protected(plan, id, reason) do
    entry = Enum.find(plan.protected, &(&1.package.id == id))
    assert entry, "expected package #{id} to be protected but it was not in plan.protected"
    assert entry.reason == reason, "expected #{id} to be protected with reason #{reason}, got #{entry.reason}"
  end

  defp assert_eligible(plan, id, reason) do
    entry = Enum.find(plan.eligible, &(&1.package.id == id))
    assert entry, "expected package #{id} to be eligible for deletion but it was not in plan.eligible"
    assert entry.reason == reason, "expected #{id} to be eligible with reason #{reason}, got #{entry.reason}"
  end
end
