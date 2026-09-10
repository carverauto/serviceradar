defmodule ServiceRadar.Repo.Migrations.AddAuditVersionActorColumns do
  @moduledoc """
  Adds `actor` / `actor_id` / `request_id` columns to the 15 AshPaperTrail
  `<resource>_versions` tables (from `ServiceRadar.Security.AuditHistory.resources/0`)
  that did not already have them.

  `ServiceRadar.Inventory.VisibilityProfile` and (a resource outside the
  audit allow-list) `ServiceRadar.SweepJobs.SweepGroupExecution` already carry
  these columns from their original table-creation migrations, alongside a
  `Changes.StampAuditContext`-style change wired into their `paper_trail`
  mixin that populates them (see
  `elixir/serviceradar_core/priv/repo/migrations/20260527123000_create_visibility_profiles.exs`).
  Every other audited resource's `version_action_inputs` never captured the
  actor at all -- AshPaperTrail only auto-populates that via `belongs_to_actor`,
  which requires the actor to be a literal struct of the configured type, and
  every real ServiceRadar actor is a plain map. This migration adds the same
  three nullable columns so `ServiceRadar.Security.Changes.StampAuditActor`
  (wired into each resource's `paper_trail` mixin alongside this migration)
  has somewhere to write.

  Hand-written, matching the existing pattern in this directory (`mix
  ash.codegen` is blocked on gitignored resource snapshots -- see
  `20260512040000_add_security_resources.exs`'s moduledoc). Idempotent via
  `IF NOT EXISTS` semantics so it is safe to re-run against a
  partially-applied database.
  """
  use Ecto.Migration

  @prefix "platform"

  @version_tables [
    "network_credential_secret_versions",
    "network_credential_rule_versions",
    "proxmox_console_session_versions",
    "ansible_controller_versions",
    "ansible_playbook_versions",
    "ansible_playbook_run_versions",
    "ansible_playbook_schedule_versions",
    "ansible_playbook_repository_versions",
    "northbound_action_provider_versions",
    "northbound_action_descriptor_versions",
    "northbound_action_invocation_versions",
    "northbound_action_event_handler_versions",
    "auth_lockout_versions",
    "authored_dashboard_versions",
    "dashboard_report_schedule_versions"
  ]

  def up do
    Enum.each(@version_tables, &add_actor_columns/1)
  end

  def down do
    Enum.each(@version_tables, &drop_actor_columns/1)
  end

  defp add_actor_columns(table_name) do
    alter table(table_name, prefix: @prefix) do
      add_if_not_exists(:actor, :map)
      add_if_not_exists(:actor_id, :text)
      add_if_not_exists(:request_id, :text)
    end
  end

  defp drop_actor_columns(table_name) do
    alter table(table_name, prefix: @prefix) do
      remove_if_exists(:actor, :map)
      remove_if_exists(:actor_id, :text)
      remove_if_exists(:request_id, :text)
    end
  end
end
