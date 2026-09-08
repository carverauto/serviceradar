defmodule ServiceRadar.Repo.Migrations.CreateRemoteAccessSessions do
  @moduledoc """
  Creates generic agent-routed remote-access session lifecycle records.

  Attach tickets are stored as hashes. Credential material is intentionally not
  represented in this schema; sessions record custody mode and scoped policy
  references only.
  """

  use Ecto.Migration

  @prefix "platform"

  def up do
    create table(:remote_access_sessions, primary_key: false, prefix: @prefix) do
      add(:id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:attach_ticket_hash, :text, null: false)
      add(:attach_expires_at, :utc_datetime, null: false)
      add(:attached_at, :utc_datetime)

      add(:status, :text, null: false, default: "requested")
      add(:device_uid, :text)
      add(:target_kind, :text, null: false, default: "inventory_device")
      add(:target_host, :text, null: false)
      add(:target_port, :integer, null: false, default: 22)
      add(:protocol, :text, null: false)
      add(:adapter, :text, null: false)
      add(:agent_id, :text, null: false)
      add(:gateway_id, :text)
      add(:credential_custody_mode, :text, null: false)

      add(
        :credential_rule_id,
        references(:network_credential_rules,
          type: :uuid,
          on_delete: :restrict,
          prefix: @prefix
        )
      )

      add(
        :requested_by,
        references(:ng_users,
          column: :id,
          type: :uuid,
          on_delete: :nilify_all,
          name: "remote_access_sessions_requested_by_fkey",
          prefix: @prefix
        )
      )

      add(:approval_id, :uuid)
      add(:rbac_decision, :text, null: false, default: "allowed")
      add(:command_id, :uuid)
      add(:idle_timeout_seconds, :integer, null: false, default: 900)
      add(:absolute_timeout_seconds, :integer, null: false, default: 3600)
      add(:opened_at, :utc_datetime)
      add(:last_activity_at, :utc_datetime)
      add(:close_requested_at, :utc_datetime)
      add(:closed_at, :utc_datetime)
      add(:close_reason, :text)
      add(:failure_reason, :text)
      add(:outcome, :text)
      add(:recording_policy, :map, null: false, default: %{})
      add(:enhanced_recording_policy, :map, null: false, default: %{})
      add(:metadata, :map, null: false, default: %{})

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
      unique_index(:remote_access_sessions, [:attach_ticket_hash],
        name: :remote_access_sessions_attach_ticket_hash_idx,
        prefix: @prefix
      )
    )

    create(
      index(:remote_access_sessions, [:device_uid, :status],
        name: :remote_access_sessions_device_status_idx,
        prefix: @prefix
      )
    )

    create(
      index(:remote_access_sessions, [:agent_id, :status],
        name: :remote_access_sessions_agent_status_idx,
        prefix: @prefix
      )
    )

    create(
      index(:remote_access_sessions, [:protocol, :status],
        name: :remote_access_sessions_protocol_status_idx,
        prefix: @prefix
      )
    )

    create(
      index(:remote_access_sessions, [:status, :attach_expires_at],
        name: :remote_access_sessions_status_attach_expires_idx,
        prefix: @prefix
      )
    )

    create(
      index(:remote_access_sessions, [:credential_rule_id],
        name: :remote_access_sessions_credential_rule_idx,
        prefix: @prefix
      )
    )

    create(
      constraint(:remote_access_sessions, :remote_access_sessions_target_port_valid,
        check: "target_port > 0 AND target_port <= 65535",
        prefix: @prefix
      )
    )

    create(
      constraint(:remote_access_sessions, :remote_access_sessions_idle_timeout_positive,
        check: "idle_timeout_seconds > 0",
        prefix: @prefix
      )
    )

    create(
      constraint(:remote_access_sessions, :remote_access_sessions_absolute_timeout_positive,
        check: "absolute_timeout_seconds > 0",
        prefix: @prefix
      )
    )

    create table(:remote_access_session_versions, primary_key: false, prefix: @prefix) do
      add(:id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:version_action_type, :text, null: false)
      add(:version_action_name, :text, null: false)
      add(:version_action_inputs, :map, null: false)

      add(
        :version_source_id,
        references(:remote_access_sessions,
          type: :uuid,
          name: "remote_access_session_versions_version_source_id_fkey",
          prefix: @prefix
        ),
        null: false
      )

      add(:changes, :map)

      add(:version_inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )

      add(:version_updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )
    end

    create(
      index(:remote_access_session_versions, [:version_source_id],
        name: :remote_access_session_versions_source_idx,
        prefix: @prefix
      )
    )
  end

  def down do
    drop_if_exists(table(:remote_access_session_versions, prefix: @prefix))
    drop_if_exists(table(:remote_access_sessions, prefix: @prefix))
  end
end
