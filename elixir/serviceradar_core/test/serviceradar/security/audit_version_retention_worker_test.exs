defmodule ServiceRadar.Security.AuditVersionRetentionWorkerTest do
  @moduledoc """
  Unit coverage for AuditVersionRetentionWorker's config resolution: the
  per-table tier defaults from the
  add-audit-history-retention-compression design (90 days for
  execution/event tables, 180 for config-audit-trail tables) and per-table
  operator overrides. The delete mechanics (cutoff, batch LIMIT, disable at
  0) are covered against a real database by
  AuditHistoryRetentionIntegrationTest.
  """
  use ExUnit.Case, async: false

  alias ServiceRadar.Security.AuditVersionRetentionWorker

  @execution_tier_tables [
    "ansible_playbook_run_versions",
    "northbound_action_invocation_versions",
    "northbound_action_event_handler_versions"
  ]

  @config_trail_tier_tables [
    "network_credential_secret_versions",
    "network_credential_rule_versions",
    "proxmox_console_session_versions",
    "ansible_controller_versions",
    "ansible_playbook_versions",
    "ansible_playbook_schedule_versions",
    "ansible_playbook_repository_versions",
    "northbound_action_provider_versions",
    "northbound_action_descriptor_versions",
    "visibility_profile_versions",
    "auth_lockout_versions",
    "authored_dashboard_versions",
    "dashboard_report_schedule_versions",
    "sweep_group_versions"
  ]

  setup do
    original = Application.get_env(:serviceradar_core, AuditVersionRetentionWorker)

    on_exit(fn ->
      if is_nil(original) do
        Application.delete_env(:serviceradar_core, AuditVersionRetentionWorker)
      else
        Application.put_env(:serviceradar_core, AuditVersionRetentionWorker, original)
      end
    end)

    :ok
  end

  test "covers every audit-history version table except the remote_access four" do
    covered = Enum.map(AuditVersionRetentionWorker.version_tables(), &elem(&1, 0))

    assert Enum.sort(covered) ==
             Enum.sort(@execution_tier_tables ++ @config_trail_tier_tables)

    # The four remote_access_*_versions tables belong to
    # RemoteAccessVersionRetentionWorker and must stay out of this worker.
    refute Enum.any?(covered, &String.starts_with?(&1, "remote_access_"))
  end

  test "execution-tier tables default to 90 days" do
    Application.delete_env(:serviceradar_core, AuditVersionRetentionWorker)

    for table <- @execution_tier_tables do
      assert AuditVersionRetentionWorker.retention_days(table) == 90,
             "#{table} should default to the 90-day execution tier"
    end
  end

  test "config-audit-trail tables default to 180 days" do
    Application.delete_env(:serviceradar_core, AuditVersionRetentionWorker)

    for table <- @config_trail_tier_tables do
      assert AuditVersionRetentionWorker.retention_days(table) == 180,
             "#{table} should default to the 180-day config-audit-trail tier"
    end
  end

  test "per-table overrides win over the tier default" do
    Application.put_env(:serviceradar_core, AuditVersionRetentionWorker,
      auth_lockout_days: 365,
      ansible_playbook_run_days: 7
    )

    assert AuditVersionRetentionWorker.retention_days("auth_lockout_versions") == 365
    assert AuditVersionRetentionWorker.retention_days("ansible_playbook_run_versions") == 7
    # Untouched tables keep their tier defaults.
    assert AuditVersionRetentionWorker.retention_days("sweep_group_versions") == 180
  end

  test "unknown tables resolve to nil (never pruned)" do
    Application.delete_env(:serviceradar_core, AuditVersionRetentionWorker)

    assert is_nil(AuditVersionRetentionWorker.retention_days("not_a_versions_table"))
  end
end
