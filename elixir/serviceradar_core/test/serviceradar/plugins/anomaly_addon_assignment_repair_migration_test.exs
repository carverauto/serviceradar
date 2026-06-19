defmodule ServiceRadar.Plugins.AnomalyAddonAssignmentRepairMigrationTest do
  use ExUnit.Case, async: true

  @migration_path "priv/repo/migrations/20260617171000_repair_anomaly_addon_empty_string_params.exs"

  test "repair migration strips only blank anomaly detector scalars for affected agents" do
    migration = File.read!(@migration_path)

    assert migration =~ "UPDATE platform.addon_assignments AS assignment"
    assert migration =~ "jsonb_each(COALESCE(assignment.params::jsonb, '{}'::jsonb))"
    assert migration =~ "jsonb_object_agg(entry.key, entry.value)"
    assert migration =~ "btrim(entry.value #>> '{}') = ''"
    assert migration =~ "agent-k8s-cp2-worker1"
    assert migration =~ "k8s-agent"
    assert migration =~
             ~S(assignment.addon_id = '#{@addon_id}' OR package.addon_id = '#{@addon_id}')

    for key <- [
          "confirm_slots",
          "checkpoint_max_age_secs",
          "max_series",
          "min_cv",
          "min_samples",
          "min_std_floor",
          "n_sigma",
          "state_max_age_secs",
          "window_size"
        ] do
      assert migration =~ key
    end

    refute migration =~ "metric_feed'"
    refute migration =~ "public.addon_assignments"
  end

  test "repair migration clears stale circuit-open read-model status" do
    migration = File.read!(@migration_path)

    assert migration =~ "DELETE FROM platform.addon_statuses AS status"
    assert migration =~ ~S(status.addon_id = '#{@addon_id}')
    assert migration =~ "status.state = 'circuit_open'"
    refute migration =~ "public.addon_statuses"
  end
end
