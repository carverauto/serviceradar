defmodule ServiceRadar.Repo.Migrations.AddAutomationCallbackGrantsFoundation do
  @moduledoc false
  use Ecto.Migration

  @prefix "platform"

  def up do
    create_callback_grants()
    create_callback_uses()
    create_callback_audit_events()
  end

  def down do
    drop_if_exists(table(:automation_callback_audit_events, prefix: @prefix))
    drop_if_exists(table(:automation_callback_uses, prefix: @prefix))
    drop_if_exists(table(:automation_callback_grants, prefix: @prefix))
  end

  defp create_callback_grants do
    create table(:automation_callback_grants, primary_key: false, prefix: @prefix) do
      add(:id, :uuid, null: false, default: fragment("uuid_generate_v7()"), primary_key: true)

      add(
        :operation_id,
        references(:ansible_automation_operations,
          type: :uuid,
          on_delete: :restrict,
          prefix: @prefix
        ),
        null: false
      )

      add(
        :execution_id,
        references(:ansible_automation_executions,
          type: :uuid,
          on_delete: :restrict,
          prefix: @prefix
        ),
        null: false
      )

      add(:tenant_id, :text, null: false)

      add(
        :controller_id,
        references(:ansible_controllers, type: :uuid, on_delete: :restrict, prefix: @prefix),
        null: false
      )

      add(
        :template_binding_id,
        references(:ansible_awx_template_bindings,
          type: :uuid,
          on_delete: :restrict,
          prefix: @prefix
        ),
        null: false
      )

      add(:inventory_id, :bigint, null: false)
      add(:job_template_id, :bigint, null: false)
      add(:project_id, :bigint, null: false)
      add(:awx_job_id, :bigint)
      add(:scm_revision, :text, null: false)
      add(:content_sha256, :text, null: false)
      add(:action, :text, null: false)
      add(:action_version, :text, null: false)
      add(:audience, :text, null: false)
      add(:response_schema_version, :text, null: false)
      add(:manifest_sha256, :text, null: false)
      add(:callback_phase, :text, null: false)
      add(:remote_access_operation, :text, null: false)
      add(:desired_state, :text, null: false)
      add(:initiator_principal_type, :text, null: false)
      add(:initiator_principal_id, :text, null: false)
      add(:authorization_version, :text, null: false)
      add(:permission_ceiling, {:array, :text}, null: false, default: [])
      add(:authority_ceiling, :map, null: false)
      add(:approval_snapshot, :map, null: false)
      add(:target_membership_ids, {:array, :uuid}, null: false, default: [])
      add(:target_snapshot, :map, null: false)
      add(:target_digest, :text, null: false)
      add(:policy_version, :text, null: false)
      add(:policy_snapshot, :map, null: false)
      add(:policy_digest, :text, null: false)
      add(:ca_key_set_digest, :text, null: false)
      add(:token_verifier, :binary, null: false)
      add(:token_pepper_version, :text, null: false)
      add(:idempotency_key_verifier, :binary, null: false)
      add(:idempotency_pepper_version, :text, null: false)
      add(:state, :text, null: false, default: "pending")
      add(:budget_limit, :integer, null: false)
      add(:budget_used, :integer, null: false, default: 0)
      add(:idempotency_policy, :text, null: false)
      add(:dispatch_agent_id, :text, null: false)
      add(:launch_envelope_ref, :text, null: false)
      add(:awx_ephemeral_credential_id, :bigint)
      add(:credential_cleanup_state, :text, null: false, default: "not_created")
      add(:credential_cleanup_attempted_at, :utc_datetime_usec)
      add(:credential_cleanup_completed_at, :utc_datetime_usec)
      add(:credential_cleanup_error_code, :text)
      add(:orphan_risk_state, :text, null: false, default: "none")
      add(:issued_at, :utc_datetime_usec, null: false)
      add(:expires_at, :utc_datetime_usec, null: false)
      add(:activated_at, :utc_datetime_usec)
      add(:consumed_at, :utc_datetime_usec)
      add(:revoked_at, :utc_datetime_usec)
      add(:expired_at, :utc_datetime_usec)
      add(:revocation_reason, :text)
      add(:inserted_at, :utc_datetime_usec, null: false, default: utc_now())
      add(:updated_at, :utc_datetime_usec, null: false, default: utc_now())
    end

    create(
      unique_index(:automation_callback_grants, [:token_verifier],
        name: "automation_callback_grants_token_verifier_uidx",
        prefix: @prefix
      )
    )

    create(
      unique_index(:automation_callback_grants, [:idempotency_key_verifier],
        name: "automation_callback_grants_idempotency_verifier_uidx",
        prefix: @prefix
      )
    )

    create(
      unique_index(
        :automation_callback_grants,
        [:execution_id, :action, :action_version, :policy_digest],
        name: "automation_callback_grants_live_partition_uidx",
        prefix: @prefix,
        where: "state IN ('pending', 'active')"
      )
    )

    create(
      index(:automation_callback_grants, [:execution_id, :state],
        name: "automation_callback_grants_execution_state_idx",
        prefix: @prefix
      )
    )

    create(
      index(:automation_callback_grants, [:state, :expires_at],
        name: "automation_callback_grants_state_expiry_idx",
        prefix: @prefix
      )
    )

    create(
      index(:automation_callback_grants, [:controller_id, :awx_job_id],
        name: "automation_callback_grants_controller_job_idx",
        prefix: @prefix,
        where: "awx_job_id IS NOT NULL"
      )
    )

    create constraint(:automation_callback_grants, :automation_callback_grants_positive_ids,
             prefix: @prefix,
             check:
               "inventory_id > 0 AND job_template_id > 0 AND project_id > 0 AND " <>
                 "(awx_job_id IS NULL OR awx_job_id > 0) AND " <>
                 "(awx_ephemeral_credential_id IS NULL OR awx_ephemeral_credential_id > 0)"
           )

    create constraint(:automation_callback_grants, :automation_callback_grants_state,
             prefix: @prefix,
             check: "state IN ('pending', 'active', 'revoked', 'expired', 'consumed')"
           )

    create constraint(:automation_callback_grants, :automation_callback_grants_principal_type,
             prefix: @prefix,
             check: "initiator_principal_type IN ('human', 'service_principal')"
           )

    create constraint(:automation_callback_grants, :automation_callback_grants_request_contract,
             prefix: @prefix,
             check:
               "callback_phase IN ('preflight', 'stage', 'verify', 'commit') AND " <>
                 "remote_access_operation = 'enroll' AND desired_state = 'present'"
           )

    create constraint(:automation_callback_grants, :automation_callback_grants_action_contract,
             prefix: @prefix,
             check:
               "action = 'remote_access.ssh_ca.bundle.read' AND " <>
                 "action_version = '1.0.0' AND " <>
                 "audience = 'serviceradar.awx.callback/v1' AND " <>
                 "response_schema_version = 'serviceradar.remote_access.ssh_ca_bundle/v1'"
           )

    create constraint(:automation_callback_grants, :automation_callback_grants_digests,
             prefix: @prefix,
             check:
               "scm_revision ~ '^[0-9a-f]{40,64}$' AND " <>
                 "content_sha256 ~ '^[0-9a-f]{64}$' AND " <>
                 "manifest_sha256 ~ '^[0-9a-f]{64}$' AND " <>
                 "target_digest ~ '^[0-9a-f]{64}$' AND " <>
                 "policy_digest ~ '^[0-9a-f]{64}$' AND " <>
                 "ca_key_set_digest ~ '^[0-9a-f]{64}$'"
           )

    create constraint(:automation_callback_grants, :automation_callback_grants_verifier,
             prefix: @prefix,
             check:
               "octet_length(token_verifier) = 32 AND " <>
                 "char_length(token_pepper_version) BETWEEN 1 AND 64 AND " <>
                 "octet_length(idempotency_key_verifier) = 32 AND " <>
                 "char_length(idempotency_pepper_version) BETWEEN 1 AND 64"
           )

    create constraint(:automation_callback_grants, :automation_callback_grants_expiry,
             prefix: @prefix,
             check:
               "expires_at > issued_at AND " <>
                 "expires_at <= issued_at + INTERVAL '600 seconds'"
           )

    create constraint(:automation_callback_grants, :automation_callback_grants_budget,
             prefix: @prefix,
             check:
               "budget_limit = 1 AND budget_used >= 0 AND budget_used <= 1 AND " <>
                 "budget_used <= budget_limit"
           )

    create constraint(:automation_callback_grants, :automation_callback_grants_targets,
             prefix: @prefix,
             check: "cardinality(target_membership_ids) BETWEEN 1 AND 100"
           )

    create constraint(:automation_callback_grants, :automation_callback_grants_permissions,
             prefix: @prefix,
             check:
               "cardinality(permission_ceiling) = 2 AND " <>
                 "permission_ceiling @> ARRAY['ansible.runs.launch', " <>
                 "'devices.remote_access.ssh.ca_bundle.read']::text[]"
           )

    create constraint(:automation_callback_grants, :automation_callback_grants_lifecycle,
             prefix: @prefix,
             check:
               "(state = 'pending' AND awx_job_id IS NULL AND activated_at IS NULL AND " <>
                 "consumed_at IS NULL AND revoked_at IS NULL AND expired_at IS NULL) OR " <>
                 "(state = 'active' AND awx_job_id IS NOT NULL AND " <>
                 "awx_ephemeral_credential_id IS NOT NULL AND activated_at IS NOT NULL AND " <>
                 "consumed_at IS NULL AND revoked_at IS NULL AND expired_at IS NULL) OR " <>
                 "(state = 'consumed' AND awx_job_id IS NOT NULL AND " <>
                 "awx_ephemeral_credential_id IS NOT NULL AND activated_at IS NOT NULL AND " <>
                 "consumed_at IS NOT NULL AND revoked_at IS NULL AND expired_at IS NULL) OR " <>
                 "(state = 'revoked' AND revoked_at IS NOT NULL AND expired_at IS NULL) OR " <>
                 "(state = 'expired' AND expired_at IS NOT NULL AND revoked_at IS NULL)"
           )

    create constraint(:automation_callback_grants, :automation_callback_grants_idempotency_policy,
             prefix: @prefix,
             check: "idempotency_policy = 'one_logical_read_per_child_policy'"
           )

    create constraint(:automation_callback_grants, :automation_callback_grants_cleanup_state,
             prefix: @prefix,
             check:
               "credential_cleanup_state IN " <>
                 "('not_created', 'pending', 'deleting', 'deleted', 'delete_failed') AND " <>
                 "orphan_risk_state IN " <>
                 "('none', 'cancel_requested', 'cancel_confirmed', 'cancel_failed') AND " <>
                 "((credential_cleanup_state = 'not_created' AND " <>
                 "awx_ephemeral_credential_id IS NULL) OR " <>
                 "(credential_cleanup_state <> 'not_created' AND " <>
                 "awx_ephemeral_credential_id IS NOT NULL)) AND " <>
                 "(credential_cleanup_state <> 'deleted' OR " <>
                 "credential_cleanup_completed_at IS NOT NULL) AND " <>
                 "(credential_cleanup_state <> 'delete_failed' OR " <>
                 "(credential_cleanup_attempted_at IS NOT NULL AND " <>
                 "credential_cleanup_error_code IS NOT NULL))"
           )
  end

  defp create_callback_uses do
    create table(:automation_callback_uses, primary_key: false, prefix: @prefix) do
      add(:id, :uuid, null: false, default: fragment("uuid_generate_v7()"), primary_key: true)

      add(
        :grant_id,
        references(:automation_callback_grants,
          type: :uuid,
          on_delete: :restrict,
          prefix: @prefix
        ),
        null: false
      )

      add(:idempotency_key_verifier, :binary, null: false)
      add(:idempotency_pepper_version, :text, null: false)
      add(:request_fingerprint, :text, null: false)
      add(:state, :text, null: false, default: "reserved")
      add(:budget_sequence, :integer)
      add(:response_reference, :text)
      add(:response_bytes, :binary)
      add(:response_fingerprint, :text)
      add(:response_size_bytes, :integer)
      add(:response_schema_version, :text)
      add(:policy_version, :text)
      add(:abort_reason, :text)
      add(:reserved_at, :utc_datetime_usec, null: false)
      add(:committed_at, :utc_datetime_usec)
      add(:aborted_at, :utc_datetime_usec)
      add(:inserted_at, :utc_datetime_usec, null: false, default: utc_now())
      add(:updated_at, :utc_datetime_usec, null: false, default: utc_now())
    end

    create(
      unique_index(:automation_callback_uses, [:grant_id, :idempotency_key_verifier],
        name: "automation_callback_uses_idempotency_uidx",
        prefix: @prefix
      )
    )

    create(
      unique_index(:automation_callback_uses, [:grant_id, :budget_sequence],
        name: "automation_callback_uses_committed_budget_uidx",
        prefix: @prefix,
        where: "state = 'committed'"
      )
    )

    create(
      index(:automation_callback_uses, [:grant_id, :state],
        name: "automation_callback_uses_grant_state_idx",
        prefix: @prefix
      )
    )

    create constraint(:automation_callback_uses, :automation_callback_uses_state,
             prefix: @prefix,
             check: "state IN ('reserved', 'committed', 'aborted')"
           )

    create constraint(:automation_callback_uses, :automation_callback_uses_response_size,
             prefix: @prefix,
             check:
               "(response_size_bytes IS NULL OR " <>
                 "(response_size_bytes >= 0 AND response_size_bytes <= 262144)) AND " <>
                 "(response_bytes IS NULL OR octet_length(response_bytes) <= 262144)"
           )

    create constraint(:automation_callback_uses, :automation_callback_uses_lifecycle,
             prefix: @prefix,
             check:
               "(state = 'reserved' AND budget_sequence IS NULL AND response_reference IS NULL AND " <>
                 "response_bytes IS NULL AND response_fingerprint IS NULL AND committed_at IS NULL AND " <>
                 "aborted_at IS NULL) OR " <>
                 "(state = 'committed' AND budget_sequence > 0 AND response_bytes IS NOT NULL AND " <>
                 "response_fingerprint IS NOT NULL AND response_size_bytes IS NOT NULL AND " <>
                 "response_schema_version IS NOT NULL AND policy_version IS NOT NULL AND " <>
                 "committed_at IS NOT NULL AND aborted_at IS NULL) OR " <>
                 "(state = 'aborted' AND abort_reason IS NOT NULL AND aborted_at IS NOT NULL AND " <>
                 "response_reference IS NULL AND response_bytes IS NULL AND committed_at IS NULL)"
           )
  end

  defp create_callback_audit_events do
    create table(:automation_callback_audit_events, primary_key: false, prefix: @prefix) do
      add(:id, :uuid, null: false, default: fragment("uuid_generate_v7()"), primary_key: true)

      add(
        :grant_id,
        references(:automation_callback_grants,
          type: :uuid,
          on_delete: :restrict,
          prefix: @prefix
        ),
        null: false
      )

      add(
        :use_id,
        references(:automation_callback_uses,
          type: :uuid,
          on_delete: :restrict,
          prefix: @prefix
        )
      )

      add(:event_key, :uuid, null: false)
      add(:event_type, :text, null: false)
      add(:outcome, :text, null: false)
      add(:tenant_id, :text, null: false)
      add(:operation_id, :uuid, null: false)
      add(:execution_id, :uuid, null: false)
      add(:controller_id, :uuid, null: false)
      add(:inventory_id, :bigint, null: false)
      add(:job_template_id, :bigint, null: false)
      add(:awx_job_id, :bigint)
      add(:action, :text, null: false)
      add(:action_version, :text, null: false)
      add(:audience, :text, null: false)
      add(:principal_type, :text, null: false)
      add(:principal_id, :text, null: false)
      add(:reason_code, :text)
      add(:policy_version, :text, null: false)
      add(:request_fingerprint, :text)
      add(:response_fingerprint, :text)
      add(:budget_before, :integer, null: false)
      add(:budget_after, :integer, null: false)
      add(:grant_state, :text, null: false)
      add(:credential_cleanup_state, :text, null: false)
      add(:occurred_at, :utc_datetime_usec, null: false)
      add(:inserted_at, :utc_datetime_usec, null: false, default: utc_now())
    end

    create(
      unique_index(:automation_callback_audit_events, [:grant_id, :event_key],
        name: "automation_callback_audit_events_key_uidx",
        prefix: @prefix
      )
    )

    create(
      index(:automation_callback_audit_events, [:grant_id, :occurred_at],
        name: "automation_callback_audit_events_grant_time_idx",
        prefix: @prefix
      )
    )

    create(
      index(:automation_callback_audit_events, [:event_type, :occurred_at],
        name: "automation_callback_audit_events_type_time_idx",
        prefix: @prefix
      )
    )

    create constraint(:automation_callback_audit_events, :automation_callback_audit_event_type,
             prefix: @prefix,
             check:
               "event_type IN ('mint_pending', 'envelope_resolved', 'credential_created', " <>
                 "'dispatch_succeeded', " <>
                 "'dispatch_failed', 'binding_activated', 'callback_allowed', " <>
                 "'callback_denied', 'callback_pending', 'callback_replay', " <>
                 "'budget_committed', 'grant_revoked', 'grant_expired', " <>
                 "'credential_delete_requested', 'credential_deleted', " <>
                 "'credential_delete_failed', 'cleanup_completed', 'misuse_detected')"
           )

    create constraint(:automation_callback_audit_events, :automation_callback_audit_outcome,
             prefix: @prefix,
             check: "outcome IN ('pending', 'allowed', 'denied', 'succeeded', 'failed')"
           )

    create constraint(:automation_callback_audit_events, :automation_callback_audit_states,
             prefix: @prefix,
             check:
               "grant_state IN ('pending', 'active', 'revoked', 'expired', 'consumed') AND " <>
                 "credential_cleanup_state IN " <>
                 "('not_created', 'pending', 'deleting', 'deleted', 'delete_failed')"
           )

    create constraint(:automation_callback_audit_events, :automation_callback_audit_bounds,
             prefix: @prefix,
             check:
               "inventory_id > 0 AND job_template_id > 0 AND " <>
                 "(awx_job_id IS NULL OR awx_job_id > 0) AND " <>
                 "budget_before >= 0 AND budget_before <= 1000 AND " <>
                 "budget_after >= 0 AND budget_after <= 1000"
           )

    create constraint(
             :automation_callback_audit_events,
             :automation_callback_audit_principal_type,
             prefix: @prefix,
             check: "principal_type IN ('human', 'service_principal')"
           )

    create constraint(:automation_callback_audit_events, :automation_callback_audit_reason_code,
             prefix: @prefix,
             check:
               "reason_code IS NULL OR reason_code IN " <>
                 "('success', 'grant_pending', 'activation_pending', " <>
                 "'authorization_denied', 'permission_missing', 'principal_disabled', " <>
                 "'tenant_mismatch', 'approval_expired', 'target_drift', 'policy_drift', " <>
                 "'revision_mismatch', 'binding_mismatch', 'job_mismatch', 'dispatch_failed', " <>
                 "'dispatch_ambiguous', 'grant_expired', 'grant_revoked', 'budget_consumed', " <>
                 "'idempotency_conflict', 'replay_authority_denied', " <>
                 "'credential_delete_failed', 'cancel_failed', 'malformed_request', " <>
                 "'misuse_detected')"
           )
  end

  defp utc_now, do: fragment("(now() AT TIME ZONE 'utc')")
end
