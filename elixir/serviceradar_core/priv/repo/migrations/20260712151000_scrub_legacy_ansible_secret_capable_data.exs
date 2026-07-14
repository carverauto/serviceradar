defmodule ServiceRadar.Repo.Migrations.ScrubLegacyAnsibleSecretCapableData do
  @moduledoc """
  Irreversibly removes legacy secret-capable Ansible launch and discovery data.

  Values are deliberately not recoverable in `down/0`; restoring an older
  backup requires running this scrub before application traffic.
  """

  use Ecto.Migration

  def up do
    # serviceradar:allow-startup-maintenance - this fail-closed security scrub
    # must finish before hardened launch code can read legacy secret-capable
    # fields. Every update is a single finite-table statement; local deadlines
    # make unexpected table growth or lock contention fail deployment instead
    # of leaving a partially scrubbed authority boundary or hanging startup.
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '2min'")

    execute("""
    UPDATE platform.ansible_playbook_runs
    SET requested_extra_vars = '{}'::jsonb,
        metadata = COALESCE(metadata, '{}'::jsonb) ||
          '{"legacy_requested_extra_vars_scrubbed":true}'::jsonb
    WHERE requested_extra_vars <> '{}'::jsonb
    """)

    execute("""
    UPDATE platform.ansible_playbook_schedules
    SET requested_extra_vars = '{}'::jsonb,
        metadata = COALESCE(metadata, '{}'::jsonb) ||
          '{"legacy_requested_extra_vars_scrubbed":true,"hardened_reapproval_required":true}'::jsonb
    WHERE requested_extra_vars <> '{}'::jsonb
    """)

    execute("""
    UPDATE platform.ansible_playbook_schedules
    SET enabled = false,
        metadata = COALESCE(metadata, '{}'::jsonb) ||
          '{"hardened_reapproval_required":true}'::jsonb
    WHERE enabled = true
    """)

    for table <- ["ansible_playbook_run_versions", "ansible_playbook_schedule_versions"] do
      execute("""
      UPDATE platform.#{table}
      SET version_action_inputs = '{}'::jsonb,
          changes = COALESCE(changes, '{}'::jsonb) - 'requested_extra_vars' - 'extra_vars'
      WHERE version_action_inputs <> '{}'::jsonb OR
            COALESCE(changes, '{}'::jsonb) ?| ARRAY['requested_extra_vars', 'extra_vars']
      """)
    end

    execute("""
    UPDATE platform.ocsf_devices
    SET metadata = jsonb_set(metadata, '{awx}', (metadata->'awx') - 'variables', true)
    WHERE jsonb_typeof(metadata->'awx') = 'object' AND metadata->'awx' ? 'variables'
    """)

    execute("""
    UPDATE platform.agent_commands
    SET result_payload = NULL,
        progress_payload = NULL
    WHERE command_type LIKE 'awx.%'
    """)

    execute("""
    UPDATE platform.agent_commands
    SET payload = COALESCE(payload, '{}'::jsonb) #- '{args,extra_vars}',
        result_payload = NULL,
        progress_payload = NULL,
        failure_reason = CASE
          WHEN status IN ('queued', 'sent', 'acknowledged', 'running')
            THEN 'legacy Ansible launch invalidated by hardened targeting migration'
          ELSE failure_reason
        END,
        status = CASE
          WHEN status IN ('queued', 'sent', 'acknowledged', 'running') THEN 'canceled'
          ELSE status
        END,
        canceled_at = CASE
          WHEN status IN ('queued', 'sent', 'acknowledged', 'running')
            THEN (now() AT TIME ZONE 'utc')
          ELSE canceled_at
        END
    WHERE command_type = 'awx.launch_job'
    """)
  end

  def down, do: :ok
end
