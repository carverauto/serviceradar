defmodule ServiceRadar.Repo.Migrations.CreateRemoteAccessDesktopTargets do
  @moduledoc """
  Creates registered desktop/RDP target policy records.

  Browsers may select only these target IDs. Upstream host, route, credential
  mode, TLS/NLA posture, redirection policy, and recording policy stay in
  trusted operator-managed state.
  """

  use Ecto.Migration

  @prefix "platform"

  def up do
    create table(:remote_access_desktop_targets, primary_key: false, prefix: @prefix) do
      add(:id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:name, :text, null: false)
      add(:description, :text)
      add(:enabled, :boolean, null: false, default: true)
      add(:protocol, :text, null: false, default: "rdp")
      add(:target_kind, :text, null: false, default: "inventory_device")
      add(:device_uid, :text, null: false)
      add(:target_host, :text, null: false)
      add(:target_port, :bigint, null: false, default: 3389)
      add(:agent_id, :text)
      add(:gateway_id, :text)
      add(:credential_custody_mode, :text, null: false, default: "user_present")

      add(
        :credential_rule_id,
        references(:network_credential_rules,
          type: :uuid,
          on_delete: :restrict,
          prefix: @prefix
        )
      )

      add(:approval_required, :boolean, null: false, default: false)
      add(:allowed_principals, {:array, :text}, null: false, default: [])
      add(:target_tls, :map, null: false, default: %{"mode" => "verify_ca"})
      add(:nla, :map, null: false, default: %{"required" => true})
      add(:screen_policy, :map, null: false, default: %{})
      add(:redirection_policy, :map, null: false, default: %{})
      add(:recording_policy, :map, null: false, default: %{"mode" => "metadata_only"})
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
      unique_index(:remote_access_desktop_targets, [:name],
        name: :remote_access_desktop_targets_unique_name_index,
        prefix: @prefix
      )
    )

    create(
      index(:remote_access_desktop_targets, [:enabled, :protocol],
        name: :remote_access_desktop_targets_enabled_protocol_idx,
        prefix: @prefix
      )
    )

    create(
      index(:remote_access_desktop_targets, [:device_uid, :enabled],
        name: :remote_access_desktop_targets_device_enabled_idx,
        prefix: @prefix
      )
    )

    create(
      index(:remote_access_desktop_targets, [:agent_id, :enabled],
        name: :remote_access_desktop_targets_agent_enabled_idx,
        prefix: @prefix
      )
    )

    create(
      index(:remote_access_desktop_targets, [:credential_rule_id],
        name: :remote_access_desktop_targets_credential_rule_idx,
        prefix: @prefix
      )
    )

    create(
      constraint(:remote_access_desktop_targets, :remote_access_desktop_targets_protocol_check,
        check: "protocol = 'rdp'",
        prefix: @prefix
      )
    )

    create(
      constraint(:remote_access_desktop_targets, :remote_access_desktop_targets_target_port_valid,
        check: "target_port BETWEEN 1 AND 65535",
        prefix: @prefix
      )
    )

    create(
      constraint(
        :remote_access_desktop_targets,
        :remote_access_desktop_targets_credential_mode_check,
        check:
          "credential_custody_mode IN ('domain_delegation', 'smart_card', 'certificate', 'user_present', 'centrally_brokered')",
        prefix: @prefix
      )
    )

    create table(:remote_access_desktop_target_versions, primary_key: false, prefix: @prefix) do
      add(:id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:version_action_type, :text, null: false)
      add(:version_action_name, :text, null: false)
      add(:version_action_inputs, :map, null: false, default: %{})

      add(
        :version_source_id,
        references(:remote_access_desktop_targets,
          type: :uuid,
          name: "remote_access_desktop_target_versions_version_source_id_fkey",
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
      index(:remote_access_desktop_target_versions, [:version_source_id],
        name: :remote_access_desktop_target_versions_source_idx,
        prefix: @prefix
      )
    )
  end

  def down do
    drop_if_exists(table(:remote_access_desktop_target_versions, prefix: @prefix))
    drop_if_exists(table(:remote_access_desktop_targets, prefix: @prefix))
  end
end
