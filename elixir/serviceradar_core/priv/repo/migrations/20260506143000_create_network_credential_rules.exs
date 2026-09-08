defmodule ServiceRadar.Repo.Migrations.CreateNetworkCredentialRules do
  @moduledoc """
  Creates reusable, edge-scoped credential rules for network integrations.

  The encrypted secret payload never leaves the `network_credential_secrets`
  table except through system actor reads used to compile agent/plugin config.
  Rules bind those secrets to SRQL device scopes and a specific edge scope so
  credentials can be tried only from the agent/gateway/partition that should
  have access to the target network.
  """

  use Ecto.Migration

  @prefix "platform"

  def up do
    create table(:network_credential_secrets, primary_key: false, prefix: @prefix) do
      add(:id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:name, :text, null: false)
      add(:description, :text)
      add(:provider, :text, null: false)
      add(:credential_kind, :text, null: false)
      add(:username, :text)
      add(:public_fingerprint, :text)
      add(:encrypted_secret_payload, :binary)
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
      unique_index(:network_credential_secrets, [:provider, :name],
        name: :network_credential_secrets_unique_provider_name_index,
        prefix: @prefix
      )
    )

    create(
      index(:network_credential_secrets, [:provider, :credential_kind],
        name: :network_credential_secrets_provider_kind_idx,
        prefix: @prefix
      )
    )

    create table(:network_credential_secret_versions, primary_key: false, prefix: @prefix) do
      add(:id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:version_action_type, :text, null: false)
      add(:version_action_name, :text, null: false)
      add(:version_action_inputs, :map, null: false)

      add(
        :version_source_id,
        references(:network_credential_secrets,
          type: :uuid,
          name: "network_credential_secret_versions_version_source_id_fkey",
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
      index(:network_credential_secret_versions, [:version_source_id],
        name: :network_credential_secret_versions_source_idx,
        prefix: @prefix
      )
    )

    create table(:network_credential_rules, primary_key: false, prefix: @prefix) do
      add(:id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:name, :text, null: false)
      add(:description, :text)
      add(:enabled, :boolean, null: false, default: true)
      add(:priority, :bigint, null: false, default: 100)
      add(:provider, :text, null: false)
      add(:auth_method, :text, null: false)
      add(:purpose, :text, null: false, default: "inventory_enrichment")
      add(:target_query, :text, null: false)
      add(:scope_type, :text, null: false)
      add(:scope_value, :text, null: false)

      add(
        :secret_id,
        references(:network_credential_secrets,
          type: :uuid,
          on_delete: :restrict,
          prefix: @prefix
        ),
        null: false
      )

      add(:allowed_ports, {:array, :bigint}, null: false, default: [])
      add(:tls_policy, :text, null: false, default: "verify")
      add(:ssh_host_key_policy, :text, null: false, default: "known_hosts")
      add(:last_test_status, :text)
      add(:last_tested_at, :utc_datetime_usec)
      add(:last_test_message, :text)
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
      unique_index(:network_credential_rules, [:provider, :scope_type, :scope_value, :name],
        name: :network_credential_rules_unique_scoped_name_index,
        prefix: @prefix
      )
    )

    create(
      index(:network_credential_rules, [:provider, :enabled, :priority],
        name: :network_credential_rules_provider_enabled_priority_idx,
        prefix: @prefix
      )
    )

    create(
      index(:network_credential_rules, [:scope_type, :scope_value, :enabled],
        name: :network_credential_rules_scope_enabled_idx,
        prefix: @prefix
      )
    )

    create(
      index(:network_credential_rules, [:secret_id],
        name: :network_credential_rules_secret_idx,
        prefix: @prefix
      )
    )

    create(
      constraint(:network_credential_rules, :network_credential_rules_priority_positive,
        check: "priority >= 0",
        prefix: @prefix
      )
    )

    create table(:network_credential_rule_versions, primary_key: false, prefix: @prefix) do
      add(:id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:version_action_type, :text, null: false)
      add(:version_action_name, :text, null: false)
      add(:version_action_inputs, :map, null: false)

      add(
        :version_source_id,
        references(:network_credential_rules,
          type: :uuid,
          name: "network_credential_rule_versions_version_source_id_fkey",
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
      index(:network_credential_rule_versions, [:version_source_id],
        name: :network_credential_rule_versions_source_idx,
        prefix: @prefix
      )
    )
  end

  def down do
    drop_if_exists(table(:network_credential_rule_versions, prefix: @prefix))
    drop_if_exists(table(:network_credential_rules, prefix: @prefix))
    drop_if_exists(table(:network_credential_secret_versions, prefix: @prefix))
    drop_if_exists(table(:network_credential_secrets, prefix: @prefix))
  end
end
