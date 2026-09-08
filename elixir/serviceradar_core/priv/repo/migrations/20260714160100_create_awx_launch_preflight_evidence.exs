defmodule ServiceRadar.Repo.Migrations.CreateAwxLaunchPreflightEvidence do
  @moduledoc false
  use Ecto.Migration

  @prefix "platform"

  def change do
    create table(:automation_awx_launch_preflight_evidences, primary_key: false, prefix: @prefix) do
      add :id, :uuid,
        primary_key: true,
        null: false,
        default: fragment("uuid_generate_v7()")

      # The command is a durable AgentCommand identifier. Deliberately do not
      # add an operation/execution column or foreign key: this evidence exists
      # before mutable execution persistence and must remain independently
      # auditable when a preflight is denied.
      add :command_id, :uuid, null: false

      add :controller_id,
          references(:ansible_controllers,
            type: :uuid,
            on_delete: :restrict,
            prefix: @prefix
          ),
          null: false

      add :dispatch_agent_id, :text, null: false
      add :dispatch_partition_id, :text, null: false

      add :binding_id,
          references(:ansible_awx_template_bindings,
            type: :uuid,
            on_delete: :restrict,
            prefix: @prefix
          ),
          null: false

      add :binding_version, :bigint, null: false
      add :approval_id, :uuid, null: false
      add :reviewed_launch_snapshot_digest, :text, null: false
      add :preflight_request_digest, :text, null: false
      add :target_snapshot_digest, :text, null: false
      add :controller_security_snapshot_digest, :text, null: false
      add :live_launch_snapshot_digest, :text, null: false
      add :command_result_digest, :text, null: false
      add :verified_at, :utc_datetime_usec, null: false
      add :expires_at, :utc_datetime_usec, null: false

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create unique_index(:automation_awx_launch_preflight_evidences, [:command_id],
             name: "automation_awx_preflight_evidence_command_uidx",
             prefix: @prefix
           )

    create index(:automation_awx_launch_preflight_evidences, [:binding_id, :verified_at],
             name: "automation_awx_preflight_evidence_binding_idx",
             prefix: @prefix
           )

    create index(:automation_awx_launch_preflight_evidences, [:controller_id, :verified_at],
             name: "automation_awx_preflight_evidence_controller_idx",
             prefix: @prefix
           )

    create constraint(
             :automation_awx_launch_preflight_evidences,
             :automation_awx_preflight_evidence_digest_check,
             check: """
             reviewed_launch_snapshot_digest ~ '^[0-9a-f]{64}$'
             AND preflight_request_digest ~ '^[0-9a-f]{64}$'
             AND target_snapshot_digest ~ '^[0-9a-f]{64}$'
             AND controller_security_snapshot_digest ~ '^[0-9a-f]{64}$'
             AND live_launch_snapshot_digest ~ '^[0-9a-f]{64}$'
             AND command_result_digest ~ '^[0-9a-f]{64}$'
             """,
             prefix: @prefix
           )

    create constraint(
             :automation_awx_launch_preflight_evidences,
             :automation_awx_preflight_evidence_bounds_check,
             check: """
             dispatch_agent_id <> ''
             AND dispatch_partition_id <> ''
             AND binding_version > 0
             AND expires_at > verified_at
             """,
             prefix: @prefix
           )
  end
end
