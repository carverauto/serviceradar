defmodule ServiceRadar.Repo.Migrations.CreateRemoteAccessFileTransfers do
  @moduledoc """
  Creates metadata-only remote-access file-transfer lifecycle records.

  File contents are not stored here. Content-audit artifact references remain
  nullable and disabled by default.
  """

  use Ecto.Migration

  @prefix "platform"

  def up do
    create table(:remote_access_file_transfers, primary_key: false, prefix: @prefix) do
      add(:id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)

      add(
        :session_id,
        references(:remote_access_sessions,
          type: :uuid,
          on_delete: :delete_all,
          prefix: @prefix
        ),
        null: false
      )

      add(:status, :text, null: false, default: "requested")
      add(:requested_by, :uuid)
      add(:device_uid, :text)
      add(:target_kind, :text, null: false, default: "inventory_device")
      add(:target_host, :text, null: false)
      add(:target_port, :integer, null: false, default: 22)
      add(:agent_id, :text, null: false)
      add(:gateway_id, :text)
      add(:operation, :text, null: false)
      add(:direction, :text, null: false)
      add(:protocol, :text, null: false, default: "sftp")
      add(:credential_custody_mode, :text, null: false)
      add(:target_path, :text, null: false)
      add(:redacted_path, :text, null: false)
      add(:path_hash, :text, null: false)
      add(:destination_path, :text)
      add(:destination_redacted_path, :text)
      add(:destination_path_hash, :text)
      add(:byte_count, :bigint, null: false, default: 0)
      add(:file_count, :bigint, null: false, default: 0)
      add(:sha256, :text)
      add(:policy_snapshot, :map, null: false, default: %{})
      add(:policy_decision, :map, null: false, default: %{})
      add(:quota_snapshot, :map, null: false, default: %{})
      add(:approval_id, :uuid)
      add(:content_audit_retained, :boolean, null: false, default: false)
      add(:content_artifact_ref, :map)
      add(:started_at, :utc_datetime)
      add(:completed_at, :utc_datetime)
      add(:retention_expires_at, :utc_datetime)
      add(:failure_reason, :text)

      add(:inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )

      add(:updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )
    end

    create(
      index(:remote_access_file_transfers, [:session_id, :status],
        name: :remote_access_file_transfers_session_status_idx,
        prefix: @prefix
      )
    )

    create(
      index(:remote_access_file_transfers, [:device_uid, :status],
        name: :remote_access_file_transfers_device_status_idx,
        prefix: @prefix
      )
    )

    create(
      index(:remote_access_file_transfers, [:agent_id, :status],
        name: :remote_access_file_transfers_agent_status_idx,
        prefix: @prefix
      )
    )

    create(
      index(:remote_access_file_transfers, [:operation, :status],
        name: :remote_access_file_transfers_operation_status_idx,
        prefix: @prefix
      )
    )

    create(
      index(:remote_access_file_transfers, [:retention_expires_at],
        name: :remote_access_file_transfers_retention_idx,
        prefix: @prefix
      )
    )

    create(
      constraint(:remote_access_file_transfers, :remote_access_file_transfers_target_port_valid,
        check: "target_port > 0 AND target_port <= 65535",
        prefix: @prefix
      )
    )

    create(
      constraint(
        :remote_access_file_transfers,
        :remote_access_file_transfers_byte_count_nonnegative,
        check: "byte_count >= 0",
        prefix: @prefix
      )
    )

    create(
      constraint(
        :remote_access_file_transfers,
        :remote_access_file_transfers_file_count_nonnegative,
        check: "file_count >= 0",
        prefix: @prefix
      )
    )

    create(
      constraint(
        :remote_access_file_transfers,
        :remote_access_file_transfers_content_artifact_policy,
        check: "content_audit_retained OR content_artifact_ref IS NULL",
        prefix: @prefix
      )
    )
  end

  def down do
    drop_if_exists(table(:remote_access_file_transfers, prefix: @prefix))
  end
end
