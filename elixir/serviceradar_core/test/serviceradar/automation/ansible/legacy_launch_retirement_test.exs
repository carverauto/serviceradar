defmodule ServiceRadar.Automation.Ansible.LegacyLaunchRetirementTest do
  use ExUnit.Case, async: true

  alias Ash.Resource.Info
  alias ServiceRadar.Automation.Ansible.PlaybookRun
  alias ServiceRadar.Automation.Ansible.PlaybookSchedule

  test "legacy resources no longer accept secret-capable raw variables" do
    refute :requested_extra_vars in Info.action(PlaybookRun, :create).accept
    refute :requested_extra_vars in Info.action(PlaybookSchedule, :create).accept
    refute :requested_extra_vars in Info.action(PlaybookSchedule, :update).accept
  end

  test "legacy schedules are created disabled and cannot be re-enabled" do
    changeset =
      Ash.Changeset.for_create(PlaybookSchedule, :create, %{
        name: "legacy schedule",
        enabled: true,
        playbook_id: Ash.UUID.generate(),
        target_device_uids: ["sr:device-1"],
        cron: "0 * * * *",
        timezone: "UTC"
      })

    assert Ash.Changeset.get_attribute(changeset, :enabled) == false

    enable = Ash.Changeset.for_update(%PlaybookSchedule{enabled: false}, :enable, %{})
    refute enable.valid?

    assert Enum.any?(enable.errors, fn error ->
             Exception.message(error) =~ "immutable execution delegation"
           end)
  end

  test "scrub migration covers live rows, audit versions, discovery, and commands" do
    migration =
      File.read!(
        Path.expand(
          "../../../../priv/repo/migrations/20260712151000_scrub_legacy_ansible_secret_capable_data.exs",
          __DIR__
        )
      )

    for required <- [
          "ansible_playbook_runs",
          "ansible_playbook_schedules",
          "ansible_playbook_run_versions",
          "ansible_playbook_schedule_versions",
          "ocsf_devices",
          "agent_commands",
          "requested_extra_vars",
          "#- '{args,extra_vars}'"
        ] do
      assert migration =~ required
    end
  end
end
