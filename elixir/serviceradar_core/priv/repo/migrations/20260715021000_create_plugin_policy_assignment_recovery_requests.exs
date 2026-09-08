defmodule ServiceRadar.Repo.Migrations.CreatePluginPolicyAssignmentRecoveryRequests do
  @moduledoc false
  use Ecto.Migration

  @prefix "platform"
  @active_states "('requested', 'executing')"
  @terminal_states "('reconciled', 'no_longer_eligible', 'owner_not_authoritative', 'identity_unavailable', 'identity_changed', 'package_unapproved', 'schema_invalid', 'conflict', 'denied', 'failed')"

  def change do
    create table(:plugin_policy_assignment_recovery_requests,
             primary_key: false,
             prefix: @prefix
           ) do
      add(:id, :uuid,
        primary_key: true,
        null: false,
        default: fragment("uuid_generate_v7()")
      )

      # The legacy assignment remains disabled/unbound forever. The request
      # stores only identifiers derived from it, never its params or any secret.
      add(:legacy_assignment_id, :uuid, null: false)
      add(:legacy_agent_uid, :text, null: false)
      add(:legacy_policy_id, :text, null: false)
      add(:legacy_plugin_package_id, :uuid, null: false)

      add(:owner_kind, :text, null: false)
      add(:owner_id, :uuid, null: false)
      add(:owner_purpose, :text)

      # Stable principal identifiers only. No bearer token, role snapshot,
      # permissions, session scope, or other reusable authorization material is
      # persisted; the executor reconstructs current authority before work.
      add(:requested_by_principal_type, :text, null: false)
      add(:requested_by_principal_id, :uuid, null: false)
      add(:requested_by_principal_owner_id, :uuid)

      add(:status, :text, null: false, default: "requested")
      add(:outcome_code, :text)
      add(:outcome_details, :map, null: false, default: %{})
      add(:replacement_assignment_ids, {:array, :uuid}, null: false, default: [])
      add(:started_at, :utc_datetime_usec)
      add(:lease_token, :uuid)
      add(:lease_expires_at, :utc_datetime_usec)
      add(:completed_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec)
    end

    create(
      unique_index(
        :plugin_policy_assignment_recovery_requests,
        [:legacy_assignment_id],
        name: "plugin_policy_assignment_recovery_requests_active_legacy_uidx",
        where: "status IN #{@active_states}",
        prefix: @prefix
      )
    )

    create(
      index(
        :plugin_policy_assignment_recovery_requests,
        [:status, :inserted_at],
        name: "plugin_policy_assignment_recovery_requests_status_idx",
        prefix: @prefix
      )
    )

    create(
      constraint(
        :plugin_policy_assignment_recovery_requests,
        :plugin_policy_assignment_recovery_requests_owner_check,
        check: """
        (owner_kind = 'plugin_target_policy' AND owner_purpose IS NULL)
        OR
        (owner_kind = 'credential_rule' AND owner_purpose IN ('inventory_enrichment', 'console_access', 'discovery', 'generic', 'camera_inventory', 'camera_stream'))
        """,
        prefix: @prefix
      )
    )

    create(
      constraint(
        :plugin_policy_assignment_recovery_requests,
        :plugin_policy_assignment_recovery_requests_principal_check,
        check: """
        (requested_by_principal_type = 'human' AND requested_by_principal_owner_id IS NULL)
        OR
        (requested_by_principal_type = 'service_principal' AND requested_by_principal_owner_id IS NOT NULL)
        """,
        prefix: @prefix
      )
    )

    create(
      constraint(
        :plugin_policy_assignment_recovery_requests,
        :plugin_policy_assignment_recovery_requests_status_check,
        check: """
        status IN ('requested', 'executing', 'reconciled', 'no_longer_eligible', 'owner_not_authoritative', 'identity_unavailable', 'identity_changed', 'package_unapproved', 'schema_invalid', 'conflict', 'denied', 'failed')
        AND (
          (status IN #{@terminal_states} AND completed_at IS NOT NULL AND lease_token IS NULL AND lease_expires_at IS NULL)
          OR
          (status = 'requested' AND completed_at IS NULL AND lease_token IS NULL AND lease_expires_at IS NULL)
          OR
          (status = 'executing' AND completed_at IS NULL AND lease_token IS NOT NULL AND lease_expires_at IS NOT NULL)
        )
        """,
        prefix: @prefix
      )
    )
  end
end
