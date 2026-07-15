defmodule ServiceRadar.Repo.Migrations.AddAutomationPreflightSnapshotEvidence do
  @moduledoc false
  use Ecto.Migration

  @prefix "platform"

  @operation_constraint "ansible_automation_operations_preflight_snapshot_pair"
  @execution_constraint "ansible_automation_executions_preflight_snapshot_pair"

  @snapshot_pair_check """
  (
    preflight_evidence_id IS NULL
    AND immutable_launch_snapshot_digest IS NULL
    AND immutable_launch_snapshot = '{}'::jsonb
  )
  OR (
    preflight_evidence_id IS NOT NULL
    AND immutable_launch_snapshot_digest IS NOT NULL
    AND immutable_launch_snapshot_digest ~ '^[0-9a-f]{64}$'
    AND jsonb_typeof(immutable_launch_snapshot) = 'object'
    AND immutable_launch_snapshot <> '{}'::jsonb
  )
  """

  def up do
    # This migration deliberately follows CreateAwxLaunchPreflightEvidence.
    # The evidence row has no reverse operation/execution relationship because
    # it must survive denied launches; these one-way FKs make successful
    # launches auditable without weakening that independence.
    alter table(:ansible_automation_operations, prefix: @prefix) do
      add :preflight_evidence_id,
          references(:automation_awx_launch_preflight_evidences,
            type: :uuid,
            on_delete: :restrict,
            prefix: @prefix
          )

      add :immutable_launch_snapshot, :map, null: false, default: %{}
      add :immutable_launch_snapshot_digest, :text
    end

    alter table(:ansible_automation_executions, prefix: @prefix) do
      add :preflight_evidence_id,
          references(:automation_awx_launch_preflight_evidences,
            type: :uuid,
            on_delete: :restrict,
            prefix: @prefix
          )

      add :immutable_launch_snapshot, :map, null: false, default: %{}
      add :immutable_launch_snapshot_digest, :text
    end

    # Default/NULL is reserved for historical rows. Any new row that carries
    # one part of the attestation must carry a non-empty object snapshot, a
    # referenced evidence row, and an exact lowercase SHA-256 digest.
    create constraint(:ansible_automation_operations, @operation_constraint,
             prefix: @prefix,
             check: @snapshot_pair_check
           )

    create constraint(:ansible_automation_executions, @execution_constraint,
             prefix: @prefix,
             check: @snapshot_pair_check
           )

    create index(:ansible_automation_operations, [:preflight_evidence_id],
             name: "ansible_automation_operations_preflight_evidence_idx",
             prefix: @prefix
           )

    create index(:ansible_automation_executions, [:preflight_evidence_id],
             name: "ansible_automation_executions_preflight_evidence_idx",
             prefix: @prefix
           )
  end

  def down do
    drop index(:ansible_automation_executions, [:preflight_evidence_id],
           name: "ansible_automation_executions_preflight_evidence_idx",
           prefix: @prefix
         )

    drop index(:ansible_automation_operations, [:preflight_evidence_id],
           name: "ansible_automation_operations_preflight_evidence_idx",
           prefix: @prefix
         )

    drop constraint(:ansible_automation_executions, @execution_constraint, prefix: @prefix)
    drop constraint(:ansible_automation_operations, @operation_constraint, prefix: @prefix)

    alter table(:ansible_automation_executions, prefix: @prefix) do
      remove :immutable_launch_snapshot_digest
      remove :immutable_launch_snapshot
      remove :preflight_evidence_id
    end

    alter table(:ansible_automation_operations, prefix: @prefix) do
      remove :immutable_launch_snapshot_digest
      remove :immutable_launch_snapshot
      remove :preflight_evidence_id
    end
  end
end
