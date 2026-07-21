defmodule ServiceRadar.Repo.Migrations.AllowPackageCredentialRecoveryPurposes do
  @moduledoc false
  use Ecto.Migration

  @prefix "platform"
  @table :plugin_policy_assignment_recovery_requests
  @constraint :plugin_policy_assignment_recovery_requests_owner_check

  def up do
    drop_if_exists(constraint(@table, @constraint, prefix: @prefix))

    create(
      constraint(
        @table,
        @constraint,
        check: """
        (owner_kind = 'plugin_target_policy' AND owner_purpose IS NULL)
        OR
        (
          owner_kind = 'credential_rule'
          AND owner_purpose ~ '^[a-z0-9][a-z0-9_.-]{0,127}$'
        )
        """,
        prefix: @prefix
      )
    )
  end

  def down do
    drop_if_exists(constraint(@table, @constraint, prefix: @prefix))

    create(
      constraint(
        @table,
        @constraint,
        check: """
        (owner_kind = 'plugin_target_policy' AND owner_purpose IS NULL)
        OR
        (owner_kind = 'credential_rule' AND owner_purpose IN ('inventory_enrichment', 'console_access', 'discovery', 'generic', 'camera_inventory', 'camera_stream'))
        """,
        prefix: @prefix
      )
    )
  end
end
