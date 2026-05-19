defmodule ServiceRadar.Automation.Ansible.RetentionWorkerTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Automation.Ansible.RetentionWorker

  defp now, do: ~U[2026-05-10 12:00:00Z]

  describe "cutoff_for/2" do
    test "nil and :disabled produce no cutoff" do
      assert RetentionWorker.cutoff_for(nil, now()) == nil
      assert RetentionWorker.cutoff_for(:disabled, now()) == nil
    end

    test "zero / negative day counts produce no cutoff" do
      assert RetentionWorker.cutoff_for(0, now()) == nil
      assert RetentionWorker.cutoff_for(-5, now()) == nil
    end

    test "non-integer values produce no cutoff" do
      assert RetentionWorker.cutoff_for("forever", now()) == nil
      assert RetentionWorker.cutoff_for(1.5, now()) == nil
    end

    test "positive integer subtracts days × 86400 seconds" do
      assert RetentionWorker.cutoff_for(1, now()) == ~U[2026-05-09 12:00:00Z]
      assert RetentionWorker.cutoff_for(90, now()) == ~U[2026-02-09 12:00:00Z]
      assert RetentionWorker.cutoff_for(365, now()) == ~U[2025-05-10 12:00:00Z]
    end
  end

  describe "pruning_plan/2" do
    test "both nil → both cutoffs nil" do
      assert RetentionWorker.pruning_plan(
               %{run_detail_days: nil, run_summary_days: nil},
               now()
             ) == %{detail_cutoff: nil, summary_cutoff: nil}
    end

    test "default-shaped config (90 detail / nil summary) yields detail cutoff only" do
      plan = RetentionWorker.pruning_plan(%{run_detail_days: 90, run_summary_days: nil}, now())
      assert plan.detail_cutoff == ~U[2026-02-09 12:00:00Z]
      assert plan.summary_cutoff == nil
    end

    test "both configured" do
      plan =
        RetentionWorker.pruning_plan(%{run_detail_days: 90, run_summary_days: 365}, now())

      assert plan.detail_cutoff == ~U[2026-02-09 12:00:00Z]
      assert plan.summary_cutoff == ~U[2025-05-10 12:00:00Z]
    end
  end

  describe "read_config/0" do
    setup do
      # Save and restore app env so async tests don't interfere -- this
      # test file is `async: false` precisely because it touches app env.
      prev_detail = Application.get_env(:serviceradar_core, :ansible_retention_run_detail_days)
      prev_summary = Application.get_env(:serviceradar_core, :ansible_retention_run_summary_days)

      on_exit(fn ->
        if prev_detail do
          Application.put_env(:serviceradar_core, :ansible_retention_run_detail_days, prev_detail)
        else
          Application.delete_env(:serviceradar_core, :ansible_retention_run_detail_days)
        end

        if prev_summary do
          Application.put_env(
            :serviceradar_core,
            :ansible_retention_run_summary_days,
            prev_summary
          )
        else
          Application.delete_env(:serviceradar_core, :ansible_retention_run_summary_days)
        end
      end)

      :ok
    end

    test "defaults: 90 detail, nil summary" do
      Application.delete_env(:serviceradar_core, :ansible_retention_run_detail_days)
      Application.delete_env(:serviceradar_core, :ansible_retention_run_summary_days)
      assert RetentionWorker.read_config() == %{run_detail_days: 90, run_summary_days: nil}
    end

    test "operator can disable detail pruning by setting 0" do
      Application.put_env(:serviceradar_core, :ansible_retention_run_detail_days, 0)
      assert RetentionWorker.read_config().run_detail_days == :disabled
    end

    test "operator can configure both" do
      Application.put_env(:serviceradar_core, :ansible_retention_run_detail_days, 30)
      Application.put_env(:serviceradar_core, :ansible_retention_run_summary_days, 180)
      cfg = RetentionWorker.read_config()
      assert cfg.run_detail_days == 30
      assert cfg.run_summary_days == 180
    end

    test "negative / non-integer values fall back to defaults" do
      Application.put_env(:serviceradar_core, :ansible_retention_run_detail_days, -1)
      Application.put_env(:serviceradar_core, :ansible_retention_run_summary_days, "forever")
      cfg = RetentionWorker.read_config()
      assert cfg.run_detail_days == 90
      assert cfg.run_summary_days == nil
    end
  end
end
