defmodule ServiceRadar.Repo.Migrations.CreateRemoteAccessRequests do
  @moduledoc """
  Creates access-request approval records for remote-access sessions.

  These records capture reviewer decisions and bind an approval to at most one
  session. They intentionally do not contain credentials or attach tickets.
  """

  use Ecto.Migration

  @prefix "platform"

  def up do
    create table(:remote_access_requests, primary_key: false, prefix: @prefix) do
      add(:id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:status, :text, null: false, default: "pending")

      add(
        :requested_by,
        references(:ng_users,
          column: :id,
          type: :uuid,
          on_delete: :nilify_all,
          name: "remote_access_requests_requested_by_fkey",
          prefix: @prefix
        ),
        null: false
      )

      add(:device_uid, :text, null: false)
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

      add(:reason, :text)
      add(:expires_at, :utc_datetime, null: false)

      add(
        :approved_by,
        references(:ng_users,
          column: :id,
          type: :uuid,
          on_delete: :nilify_all,
          name: "remote_access_requests_approved_by_fkey",
          prefix: @prefix
        )
      )

      add(:approved_at, :utc_datetime)

      add(
        :denied_by,
        references(:ng_users,
          column: :id,
          type: :uuid,
          on_delete: :nilify_all,
          name: "remote_access_requests_denied_by_fkey",
          prefix: @prefix
        )
      )

      add(:denied_at, :utc_datetime)
      add(:denial_reason, :text)
      add(:review_note, :text)
      add(:expired_at, :utc_datetime)

      add(
        :session_id,
        references(:remote_access_sessions,
          type: :uuid,
          on_delete: :nilify_all,
          prefix: @prefix
        )
      )

      add(:bound_at, :utc_datetime)
      add(:reviewer_policy, :map, null: false, default: %{})
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
      index(:remote_access_requests, [:requested_by, :status],
        name: :remote_access_requests_requester_status_idx,
        prefix: @prefix
      )
    )

    create(
      index(:remote_access_requests, [:device_uid, :status],
        name: :remote_access_requests_device_status_idx,
        prefix: @prefix
      )
    )

    create(
      index(:remote_access_requests, [:status, :expires_at],
        name: :remote_access_requests_status_expires_idx,
        prefix: @prefix
      )
    )

    create(
      unique_index(:remote_access_requests, [:session_id],
        name: :remote_access_requests_session_uidx,
        where: "session_id IS NOT NULL",
        prefix: @prefix
      )
    )

    create(
      constraint(:remote_access_requests, :remote_access_requests_target_port_valid,
        check: "target_port > 0 AND target_port <= 65535",
        prefix: @prefix
      )
    )

    create table(:remote_access_request_versions, primary_key: false, prefix: @prefix) do
      add(:id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:version_action_type, :text, null: false)
      add(:version_action_name, :text, null: false)
      add(:version_action_inputs, :map, null: false)

      add(
        :version_source_id,
        references(:remote_access_requests,
          type: :uuid,
          name: "remote_access_request_versions_version_source_id_fkey",
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
      index(:remote_access_request_versions, [:version_source_id],
        name: :remote_access_request_versions_source_idx,
        prefix: @prefix
      )
    )
  end

  def down do
    drop_if_exists(table(:remote_access_request_versions, prefix: @prefix))
    drop_if_exists(table(:remote_access_requests, prefix: @prefix))
  end
end
