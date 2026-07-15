defmodule ServiceRadar.Repo.Migrations.HardenAnsibleAwxTargetingFoundation do
  @moduledoc false
  use Ecto.Migration

  @prefix "platform"

  def up do
    create_awx_host_memberships()
    create_automation_operations()
    create_automation_execution_delegations()
    create_automation_executions()
    create_automation_execution_targets()
    create_automation_mutation_phases()
    create_automation_target_holds()
  end

  def down do
    drop_if_exists(table(:ansible_automation_target_holds, prefix: @prefix))
    drop_if_exists(table(:ansible_automation_mutation_phases, prefix: @prefix))
    drop_if_exists(table(:ansible_automation_execution_targets, prefix: @prefix))
    drop_if_exists(table(:ansible_automation_executions, prefix: @prefix))
    drop_if_exists(table(:ansible_automation_execution_delegations, prefix: @prefix))
    drop_if_exists(table(:ansible_automation_operations, prefix: @prefix))
    drop_if_exists(table(:ansible_awx_host_memberships, prefix: @prefix))
  end

  defp create_awx_host_memberships do
    create table(:ansible_awx_host_memberships, primary_key: false, prefix: @prefix) do
      add(:id, :uuid, null: false, default: fragment("uuid_generate_v7()"), primary_key: true)

      add(
        :controller_id,
        references(:ansible_controllers, type: :uuid, on_delete: :delete_all, prefix: @prefix),
        null: false
      )

      add(:inventory_id, :bigint, null: false)
      add(:awx_host_id, :bigint, null: false)

      add(
        :canonical_device_uid,
        references(:ocsf_devices,
          column: :uid,
          type: :text,
          on_delete: :nilify_all,
          prefix: @prefix
        )
      )

      add(:source_generation, :bigint, null: false)
      add(:host_name, :text, null: false)
      add(:ansible_host, :text)
      add(:enabled, :boolean, null: false, default: true)
      add(:current, :boolean, null: false, default: true)
      add(:last_seen_at, :utc_datetime_usec, null: false)
      add(:expired_at, :utc_datetime_usec)
      add(:link_disposition, :text, null: false, default: "unlinked")
      add(:link_evidence, :map, null: false, default: %{})
      add(:source_fingerprint, :text, null: false)
      add(:metadata, :map, null: false, default: %{})
      add(:inserted_at, :utc_datetime_usec, null: false, default: utc_now())
      add(:updated_at, :utc_datetime_usec, null: false, default: utc_now())
    end

    create(
      unique_index(:ansible_awx_host_memberships, [:controller_id, :inventory_id, :awx_host_id],
        name: "ansible_awx_host_memberships_source_identity_uidx",
        prefix: @prefix
      )
    )

    create(
      index(:ansible_awx_host_memberships, [:canonical_device_uid, :current],
        name: "ansible_awx_host_memberships_device_current_idx",
        prefix: @prefix
      )
    )

    create(
      index(:ansible_awx_host_memberships, [:controller_id, :inventory_id, :current],
        name: "ansible_awx_host_memberships_inventory_current_idx",
        prefix: @prefix
      )
    )

    create constraint(:ansible_awx_host_memberships, :ansible_awx_host_memberships_positive_ids,
             prefix: @prefix,
             check: "inventory_id > 0 AND awx_host_id > 0 AND source_generation > 0"
           )

    create constraint(
             :ansible_awx_host_memberships,
             :ansible_awx_host_memberships_link_disposition,
             prefix: @prefix,
             check: "link_disposition IN ('unlinked', 'proposed', 'approved', 'quarantined')"
           )

    create constraint(:ansible_awx_host_memberships, :ansible_awx_host_memberships_currentness,
             prefix: @prefix,
             check: "(current AND expired_at IS NULL) OR (NOT current AND expired_at IS NOT NULL)"
           )

    create constraint(:ansible_awx_host_memberships, :ansible_awx_host_memberships_approved_link,
             prefix: @prefix,
             check: "link_disposition <> 'approved' OR canonical_device_uid IS NOT NULL"
           )
  end

  defp create_automation_operations do
    create table(:ansible_automation_operations, primary_key: false, prefix: @prefix) do
      add(:id, :uuid, null: false, default: fragment("uuid_generate_v7()"), primary_key: true)
      add(:tenant_id, :text, null: false)
      add(:action, :text, null: false)
      add(:state, :text, null: false, default: "planned")
      add(:mutating, :boolean, null: false, default: true)
      add(:check_mode, :boolean, null: false, default: false)
      add(:initiator_principal_type, :text, null: false)
      add(:initiator_principal_id, :text, null: false)
      add(:service_principal_owner_id, :text)
      add(:authorization_version, :text, null: false)
      add(:authority_ceiling, :map, null: false)
      add(:approval_snapshot, :map, null: false, default: %{})
      add(:request_source, :text, null: false)
      add(:declared_inputs, :map, null: false, default: %{})
      add(:input_classifications, :map, null: false, default: %{})
      add(:input_digest, :text, null: false)
      add(:target_digest, :text, null: false)
      add(:callback_actions, {:array, :text}, null: false, default: [])
      add(:run_budget, :map, null: false, default: %{})
      add(:diagnostics, :map, null: false, default: %{})
      add(:metadata, :map, null: false, default: %{})
      add(:started_at, :utc_datetime_usec)
      add(:ended_at, :utc_datetime_usec)
      add(:inserted_at, :utc_datetime_usec, null: false, default: utc_now())
      add(:updated_at, :utc_datetime_usec, null: false, default: utc_now())
    end

    create(
      index(:ansible_automation_operations, [:state, :inserted_at],
        name: "ansible_automation_operations_state_idx",
        prefix: @prefix
      )
    )

    create constraint(:ansible_automation_operations, :ansible_automation_operations_state,
             prefix: @prefix,
             check:
               "state IN ('planned', 'dispatching', 'running', 'succeeded', 'failed', 'canceled', " <>
                 "'dispatch_partial', 'dispatch_ambiguous', 'cancel_failed')"
           )

    create constraint(
             :ansible_automation_operations,
             :ansible_automation_operations_principal_type,
             prefix: @prefix,
             check: "initiator_principal_type IN ('human', 'service_principal')"
           )
  end

  defp create_automation_execution_delegations do
    create table(:ansible_automation_execution_delegations,
             primary_key: false,
             prefix: @prefix
           ) do
      add(:id, :uuid, null: false, default: fragment("uuid_generate_v7()"), primary_key: true)

      add(
        :schedule_id,
        references(:ansible_playbook_schedules,
          type: :uuid,
          on_delete: :delete_all,
          prefix: @prefix
        )
      )

      add(:tenant_id, :text, null: false)
      add(:issuer_principal_type, :text, null: false)
      add(:issuer_principal_id, :text, null: false)
      add(:owner_principal_id, :text, null: false)
      add(:execution_principal_type, :text, null: false)
      add(:execution_principal_id, :text, null: false)
      add(:authorization_version, :text, null: false)
      add(:permission_ceiling, {:array, :text}, null: false, default: [])
      add(:action_ceiling, :map, null: false, default: %{})
      add(:target_membership_ids, {:array, :uuid}, null: false, default: [])
      add(:non_secret_input_ceiling, :map, null: false, default: %{})
      add(:approval_snapshot, :map, null: false, default: %{})
      add(:run_budget, :map, null: false, default: %{})
      add(:status, :text, null: false, default: "active")
      add(:issued_at, :utc_datetime_usec, null: false)
      add(:expires_at, :utc_datetime_usec, null: false)
      add(:revoked_at, :utc_datetime_usec)
      add(:revocation_reason, :text)
      add(:metadata, :map, null: false, default: %{})
      add(:inserted_at, :utc_datetime_usec, null: false, default: utc_now())
      add(:updated_at, :utc_datetime_usec, null: false, default: utc_now())
    end

    create(
      index(:ansible_automation_execution_delegations, [:schedule_id, :status],
        name: "ansible_automation_execution_delegations_schedule_idx",
        prefix: @prefix
      )
    )

    create constraint(
             :ansible_automation_execution_delegations,
             :ansible_automation_execution_delegations_principal_types,
             prefix: @prefix,
             check:
               "issuer_principal_type IN ('human', 'service_principal') AND " <>
                 "execution_principal_type IN ('human', 'service_principal')"
           )

    create constraint(
             :ansible_automation_execution_delegations,
             :ansible_automation_execution_delegations_status,
             prefix: @prefix,
             check: "status IN ('active', 'expired', 'revoked', 'invalidated')"
           )

    create constraint(
             :ansible_automation_execution_delegations,
             :ansible_automation_execution_delegations_expiry,
             prefix: @prefix,
             check: "expires_at > issued_at"
           )
  end

  defp create_automation_executions do
    create table(:ansible_automation_executions, primary_key: false, prefix: @prefix) do
      add(:id, :uuid, null: false, default: fragment("uuid_generate_v7()"), primary_key: true)

      add(
        :operation_id,
        references(:ansible_automation_operations,
          type: :uuid,
          on_delete: :delete_all,
          prefix: @prefix
        ),
        null: false
      )

      add(
        :controller_id,
        references(:ansible_controllers, type: :uuid, on_delete: :restrict, prefix: @prefix),
        null: false
      )

      add(:inventory_id, :bigint, null: false)
      add(:job_template_id, :bigint, null: false)
      add(:project_id, :bigint, null: false)
      add(:scm_revision, :text, null: false)
      add(:content_sha256, :text, null: false)
      add(:execution_environment_id, :bigint, null: false)
      add(:machine_credential_id, :bigint, null: false)
      add(:credential_snapshot, :map, null: false, default: %{})
      add(:check_mode, :boolean, null: false, default: false)
      add(:host_limit, :text, null: false)
      add(:dispatch_id, :uuid, null: false)
      add(:snapshot_digest, :text, null: false)
      add(:state, :text, null: false, default: "planned")
      add(:awx_job_id, :bigint)
      add(:accepted_job_snapshot, :map, null: false, default: %{})
      add(:scope_verified_at, :utc_datetime_usec)
      add(:callback_reference, :text)
      add(:started_at, :utc_datetime_usec)
      add(:ended_at, :utc_datetime_usec)
      add(:diagnostics, :map, null: false, default: %{})
      add(:metadata, :map, null: false, default: %{})
      add(:inserted_at, :utc_datetime_usec, null: false, default: utc_now())
      add(:updated_at, :utc_datetime_usec, null: false, default: utc_now())
    end

    create(
      unique_index(:ansible_automation_executions, [:dispatch_id],
        name: "ansible_automation_executions_dispatch_uidx",
        prefix: @prefix
      )
    )

    create(
      unique_index(:ansible_automation_executions, [:controller_id, :awx_job_id],
        name: "ansible_automation_executions_controller_job_uidx",
        prefix: @prefix,
        where: "awx_job_id IS NOT NULL"
      )
    )

    create(
      index(:ansible_automation_executions, [:operation_id, :state],
        name: "ansible_automation_executions_operation_state_idx",
        prefix: @prefix
      )
    )

    create constraint(:ansible_automation_executions, :ansible_automation_executions_positive_ids,
             prefix: @prefix,
             check:
               "inventory_id > 0 AND job_template_id > 0 AND project_id > 0 AND " <>
                 "execution_environment_id > 0 AND machine_credential_id > 0"
           )

    create constraint(:ansible_automation_executions, :ansible_automation_executions_host_limit,
             prefix: @prefix,
             check: "length(btrim(host_limit)) > 0"
           )

    create constraint(:ansible_automation_executions, :ansible_automation_executions_state,
             prefix: @prefix,
             check:
               "state IN ('planned', 'dispatching', 'launching', 'scope_verified', 'running', " <>
                 "'succeeded', 'failed', 'canceled', 'dispatch_ambiguous', 'cancel_failed')"
           )
  end

  defp create_automation_execution_targets do
    create table(:ansible_automation_execution_targets, primary_key: false, prefix: @prefix) do
      add(:id, :uuid, null: false, default: fragment("uuid_generate_v7()"), primary_key: true)

      add(
        :execution_id,
        references(:ansible_automation_executions,
          type: :uuid,
          on_delete: :delete_all,
          prefix: @prefix
        ),
        null: false
      )

      add(
        :membership_id,
        references(:ansible_awx_host_memberships,
          type: :uuid,
          on_delete: :restrict,
          prefix: @prefix
        ),
        null: false
      )

      add(
        :canonical_device_uid,
        references(:ocsf_devices,
          column: :uid,
          type: :text,
          on_delete: :restrict,
          prefix: @prefix
        ),
        null: false
      )

      add(
        :controller_id,
        references(:ansible_controllers, type: :uuid, on_delete: :restrict, prefix: @prefix),
        null: false
      )

      add(:inventory_id, :bigint, null: false)
      add(:awx_host_id, :bigint, null: false)
      add(:membership_generation, :bigint, null: false)
      add(:host_name, :text, null: false)
      add(:ansible_host, :text)
      add(:status, :text, null: false, default: "pending")
      add(:snapshot_digest, :text, null: false)
      add(:diagnostics, :map, null: false, default: %{})
      add(:inserted_at, :utc_datetime_usec, null: false, default: utc_now())
      add(:updated_at, :utc_datetime_usec, null: false, default: utc_now())
    end

    create(
      unique_index(:ansible_automation_execution_targets, [:execution_id, :membership_id],
        name: "ansible_automation_execution_targets_membership_uidx",
        prefix: @prefix
      )
    )

    create(
      unique_index(:ansible_automation_execution_targets, [:execution_id, :awx_host_id],
        name: "ansible_automation_execution_targets_awx_host_uidx",
        prefix: @prefix
      )
    )

    create(
      unique_index(:ansible_automation_execution_targets, [:execution_id, :canonical_device_uid],
        name: "ansible_automation_execution_targets_device_uidx",
        prefix: @prefix
      )
    )

    create(
      index(:ansible_automation_execution_targets, [:canonical_device_uid, :inserted_at],
        name: "ansible_automation_execution_targets_device_idx",
        prefix: @prefix
      )
    )

    create constraint(
             :ansible_automation_execution_targets,
             :ansible_automation_execution_targets_positive_ids,
             prefix: @prefix,
             check: "inventory_id > 0 AND awx_host_id > 0 AND membership_generation > 0"
           )

    create constraint(
             :ansible_automation_execution_targets,
             :ansible_automation_execution_targets_status,
             prefix: @prefix,
             check:
               "status IN ('pending', 'running', 'ok', 'failed', 'unreachable', 'skipped', " <>
                 "'scope_mismatch', 'canceled')"
           )
  end

  defp create_automation_mutation_phases do
    create table(:ansible_automation_mutation_phases, primary_key: false, prefix: @prefix) do
      add(:id, :uuid, null: false, default: fragment("uuid_generate_v7()"), primary_key: true)

      add(
        :execution_target_id,
        references(:ansible_automation_execution_targets,
          type: :uuid,
          on_delete: :delete_all,
          prefix: @prefix
        ),
        null: false
      )

      add(:transaction_id, :uuid, null: false)
      add(:generation, :bigint, null: false)
      add(:idempotency_key, :text, null: false)
      add(:previous_phase, :text)
      add(:phase, :text, null: false)
      add(:action, :text, null: false)
      add(:template_id, :bigint, null: false)
      add(:scm_revision, :text, null: false)
      add(:policy_digest, :text, null: false)
      add(:outcome_digest, :text, null: false)
      add(:evidence_digest, :text, null: false)
      add(:authenticated_source, :map, null: false)
      add(:deadline_at, :utc_datetime_usec, null: false)
      add(:occurred_at, :utc_datetime_usec, null: false)
      add(:metadata, :map, null: false, default: %{})
      add(:inserted_at, :utc_datetime_usec, null: false, default: utc_now())
    end

    create(
      unique_index(
        :ansible_automation_mutation_phases,
        [:execution_target_id, :idempotency_key],
        name: "ansible_automation_mutation_phases_idempotency_uidx",
        prefix: @prefix
      )
    )

    create(
      unique_index(
        :ansible_automation_mutation_phases,
        [:execution_target_id, :transaction_id, :generation],
        name: "ansible_automation_mutation_phases_transaction_generation_uidx",
        prefix: @prefix
      )
    )

    create(
      index(
        :ansible_automation_mutation_phases,
        [:execution_target_id, :generation, :occurred_at],
        name: "ansible_automation_mutation_phases_target_generation_idx",
        prefix: @prefix
      )
    )

    create constraint(
             :ansible_automation_mutation_phases,
             :ansible_automation_mutation_phases_positive,
             prefix: @prefix,
             check: "generation > 0 AND template_id > 0"
           )

    create constraint(
             :ansible_automation_mutation_phases,
             :ansible_automation_mutation_phases_phase,
             prefix: @prefix,
             check:
               "phase IN ('initial', 'staged', 'verified', 'committed', 'rolled_back', 'critical', 'unknown')"
           )

    create constraint(
             :ansible_automation_mutation_phases,
             :ansible_automation_mutation_phases_previous_phase,
             prefix: @prefix,
             check:
               "previous_phase IS NULL OR previous_phase IN " <>
                 "('initial', 'staged', 'verified', 'committed', 'rolled_back', 'critical', 'unknown')"
           )
  end

  defp create_automation_target_holds do
    create table(:ansible_automation_target_holds, primary_key: false, prefix: @prefix) do
      add(:id, :uuid, null: false, default: fragment("uuid_generate_v7()"), primary_key: true)

      add(
        :canonical_device_uid,
        references(:ocsf_devices,
          column: :uid,
          type: :text,
          on_delete: :restrict,
          prefix: @prefix
        ),
        null: false
      )

      add(
        :trigger_membership_id,
        references(:ansible_awx_host_memberships,
          type: :uuid,
          on_delete: :restrict,
          prefix: @prefix
        ),
        null: false
      )

      add(
        :trigger_execution_target_id,
        references(:ansible_automation_execution_targets,
          type: :uuid,
          on_delete: :restrict,
          prefix: @prefix
        ),
        null: false
      )

      add(:transaction_id, :uuid, null: false)
      add(:generation, :bigint, null: false)
      add(:trigger_phase, :text, null: false)
      add(:reason, :text, null: false)
      add(:policy_digest, :text, null: false)
      add(:evidence_digest, :text, null: false)
      add(:active, :boolean, null: false, default: true)
      add(:held_at, :utc_datetime_usec, null: false)
      add(:cleared_at, :utc_datetime_usec)
      add(:cleared_by_principal_type, :text)
      add(:cleared_by_principal_id, :text)
      add(:clearance_approval_id, :uuid)
      add(:clearance_policy_digest, :text)
      add(:clearance_evidence, :map)
      add(:diagnostics, :map, null: false, default: %{})
      add(:metadata, :map, null: false, default: %{})
      add(:inserted_at, :utc_datetime_usec, null: false, default: utc_now())
      add(:updated_at, :utc_datetime_usec, null: false, default: utc_now())
    end

    create(
      unique_index(:ansible_automation_target_holds, [:canonical_device_uid],
        name: "ansible_automation_target_holds_active_device_uidx",
        prefix: @prefix,
        where: "active"
      )
    )

    create(
      index(:ansible_automation_target_holds, [:canonical_device_uid, :held_at],
        name: "ansible_automation_target_holds_device_history_idx",
        prefix: @prefix
      )
    )

    create constraint(
             :ansible_automation_target_holds,
             :ansible_automation_target_holds_generation,
             prefix: @prefix,
             check: "generation > 0"
           )

    create constraint(:ansible_automation_target_holds, :ansible_automation_target_holds_phase,
             prefix: @prefix,
             check: "trigger_phase IN ('staged', 'verified', 'critical', 'unknown')"
           )

    create constraint(
             :ansible_automation_target_holds,
             :ansible_automation_target_holds_clearance,
             prefix: @prefix,
             check:
               "(active AND cleared_at IS NULL AND cleared_by_principal_type IS NULL AND " <>
                 "cleared_by_principal_id IS NULL AND clearance_approval_id IS NULL AND " <>
                 "clearance_policy_digest IS NULL AND clearance_evidence IS NULL) OR " <>
                 "(NOT active AND cleared_at IS NOT NULL AND cleared_by_principal_type IS NOT NULL AND " <>
                 "cleared_by_principal_id IS NOT NULL AND clearance_approval_id IS NOT NULL AND " <>
                 "clearance_policy_digest IS NOT NULL AND clearance_evidence IS NOT NULL)"
           )
  end

  defp utc_now, do: fragment("(now() AT TIME ZONE 'utc')")
end
