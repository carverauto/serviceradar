defmodule ServiceRadar.Repo.Migrations.CreateProxmoxConsoleSessions do
  @moduledoc """
  Creates short-lived Proxmox browser console session tickets.

  Tickets are generated in web-ng, returned to the browser once, and stored
  only as SHA-256 hashes. Console credentials remain in network credential
  rules/secrets; this table records the scoped rule and lifecycle metadata.
  """

  use Ecto.Migration

  @prefix "platform"

  def up do
    create table(:proxmox_console_sessions, primary_key: false, prefix: @prefix) do
      add(:id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:ticket_hash, :text, null: false)
      add(:ticket_expires_at, :utc_datetime, null: false)
      add(:ticket_used_at, :utc_datetime)

      add(:status, :text, null: false, default: "requested")
      add(:device_uid, :text, null: false)
      add(:target_kind, :text, null: false)
      add(:console_mode, :text, null: false)
      add(:agent_id, :text, null: false)
      add(:gateway_id, :text)

      add(
        :credential_rule_id,
        references(:network_credential_rules,
          type: :uuid,
          on_delete: :restrict,
          prefix: @prefix
        ),
        null: false
      )

      add(
        :requested_by,
        references(:ng_users,
          column: :id,
          type: :uuid,
          on_delete: :nilify_all,
          name: "proxmox_console_sessions_requested_by_fkey",
          prefix: @prefix
        )
      )

      add(:command_id, :uuid)
      add(:idle_timeout_seconds, :integer, null: false, default: 900)
      add(:absolute_timeout_seconds, :integer, null: false, default: 3600)
      add(:opened_at, :utc_datetime)
      add(:last_activity_at, :utc_datetime)
      add(:close_requested_at, :utc_datetime)
      add(:closed_at, :utc_datetime)
      add(:close_reason, :text)
      add(:failure_reason, :text)
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
      unique_index(:proxmox_console_sessions, [:ticket_hash],
        name: :proxmox_console_sessions_ticket_hash_idx,
        prefix: @prefix
      )
    )

    create(
      index(:proxmox_console_sessions, [:device_uid, :status],
        name: :proxmox_console_sessions_device_status_idx,
        prefix: @prefix
      )
    )

    create(
      index(:proxmox_console_sessions, [:agent_id, :status],
        name: :proxmox_console_sessions_agent_status_idx,
        prefix: @prefix
      )
    )

    create(
      index(:proxmox_console_sessions, [:status, :ticket_expires_at],
        name: :proxmox_console_sessions_status_ticket_expires_idx,
        prefix: @prefix
      )
    )

    create(
      index(:proxmox_console_sessions, [:credential_rule_id],
        name: :proxmox_console_sessions_credential_rule_idx,
        prefix: @prefix
      )
    )

    create(
      constraint(:proxmox_console_sessions, :proxmox_console_sessions_idle_timeout_positive,
        check: "idle_timeout_seconds > 0",
        prefix: @prefix
      )
    )

    create(
      constraint(:proxmox_console_sessions, :proxmox_console_sessions_absolute_timeout_positive,
        check: "absolute_timeout_seconds > 0",
        prefix: @prefix
      )
    )

    create table(:proxmox_console_session_versions, primary_key: false, prefix: @prefix) do
      add(:id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:version_action_type, :text, null: false)
      add(:version_action_name, :text, null: false)
      add(:version_action_inputs, :map, null: false)

      add(
        :version_source_id,
        references(:proxmox_console_sessions,
          type: :uuid,
          name: "proxmox_console_session_versions_version_source_id_fkey",
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
      index(:proxmox_console_session_versions, [:version_source_id],
        name: :proxmox_console_session_versions_source_idx,
        prefix: @prefix
      )
    )
  end

  def down do
    drop_if_exists(table(:proxmox_console_session_versions, prefix: @prefix))
    drop_if_exists(table(:proxmox_console_sessions, prefix: @prefix))
  end
end
