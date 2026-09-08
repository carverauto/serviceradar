defmodule ServiceRadar.Repo.Migrations.CreateRemoteAccessHostKeys do
  @moduledoc """
  Creates SSH host-key trust state for agent-routed remote access.

  The table stores observed target host public keys, fingerprints, trust
  lifecycle state, and audit-oriented metadata. It does not store login
  credentials or reusable user secrets.
  """

  use Ecto.Migration

  @prefix "platform"

  def up do
    create table(:remote_access_host_keys, primary_key: false, prefix: @prefix) do
      add(:id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:device_uid, :text)
      add(:target_host, :text, null: false)
      add(:target_port, :integer, null: false, default: 22)
      add(:protocol, :text, null: false, default: "ssh")
      add(:agent_id, :text, null: false)
      add(:gateway_id, :text)
      add(:key_type, :text, null: false)
      add(:fingerprint_sha256, :text, null: false)
      add(:public_key, :text)
      add(:status, :text, null: false, default: "pending")
      add(:source, :text, null: false, default: "agent_observed")
      add(:first_seen_at, :utc_datetime, null: false)
      add(:last_seen_at, :utc_datetime, null: false)
      add(:seen_count, :integer, null: false, default: 1)
      add(:trusted_at, :utc_datetime)
      add(:trusted_by, :text)
      add(:revoked_at, :utc_datetime)
      add(:revoked_by, :text)
      add(:revocation_reason, :text)
      add(:rotated_at, :utc_datetime)
      add(:rotated_by, :text)
      add(:replacement_host_key_id, :uuid)
      add(:rotation_reason, :text)
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

    alter table(:remote_access_host_keys, prefix: @prefix) do
      modify(
        :replacement_host_key_id,
        references(:remote_access_host_keys,
          type: :uuid,
          on_delete: :nilify_all,
          name: "remote_access_host_keys_replacement_fkey",
          prefix: @prefix
        )
      )
    end

    create(
      unique_index(
        :remote_access_host_keys,
        [:agent_id, :target_host, :target_port, :protocol, :fingerprint_sha256],
        name: :remote_access_host_keys_target_fingerprint_idx,
        prefix: @prefix
      )
    )

    create(
      index(:remote_access_host_keys, [:device_uid, :status],
        name: :remote_access_host_keys_device_status_idx,
        prefix: @prefix
      )
    )

    create(
      index(:remote_access_host_keys, [:agent_id, :target_host, :target_port, :protocol, :status],
        name: :remote_access_host_keys_target_status_idx,
        prefix: @prefix
      )
    )

    create(
      constraint(:remote_access_host_keys, :remote_access_host_keys_target_port_valid,
        check: "target_port > 0 AND target_port <= 65535",
        prefix: @prefix
      )
    )

    create(
      constraint(:remote_access_host_keys, :remote_access_host_keys_seen_count_positive,
        check: "seen_count > 0",
        prefix: @prefix
      )
    )

    create table(:remote_access_host_key_versions, primary_key: false, prefix: @prefix) do
      add(:id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:version_action_type, :text, null: false)
      add(:version_action_name, :text, null: false)
      add(:version_action_inputs, :map, null: false)

      add(
        :version_source_id,
        references(:remote_access_host_keys,
          type: :uuid,
          name: "remote_access_host_key_versions_version_source_id_fkey",
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
      index(:remote_access_host_key_versions, [:version_source_id],
        name: :remote_access_host_key_versions_source_idx,
        prefix: @prefix
      )
    )
  end

  def down do
    drop_if_exists(table(:remote_access_host_key_versions, prefix: @prefix))
    drop_if_exists(table(:remote_access_host_keys, prefix: @prefix))
  end
end
