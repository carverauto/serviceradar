defmodule ServiceRadar.Repo.Migrations.AddExternalSecretProviderBroker do
  @moduledoc false
  use Ecto.Migration

  @prefix "platform"

  def change do
    create table(:credential_secret_providers, primary_key: false, prefix: @prefix) do
      add(:id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:name, :text, null: false)
      add(:description, :text)
      add(:provider_type, :text, null: false)
      add(:endpoint_url, :text)
      add(:auth_mode, :text, null: false, default: "deployment_secret")
      add(:resolution_locations, {:array, :text}, null: false, default: [])
      add(:enabled, :boolean, null: false, default: false)
      add(:status, :text, null: false, default: "disabled")
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

    create unique_index(:credential_secret_providers, [:name],
             prefix: @prefix,
             name: :credential_secret_providers_name_idx
           )

    create index(:credential_secret_providers, [:provider_type, :enabled],
             prefix: @prefix,
             name: :credential_secret_providers_type_enabled_idx
           )

    create table(:credential_secret_provider_versions, primary_key: false, prefix: @prefix) do
      add(:id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:version_action_type, :text, null: false)
      add(:version_action_name, :text, null: false)
      add(:version_action_inputs, :map, null: false)

      add(
        :version_source_id,
        references(:credential_secret_providers,
          type: :uuid,
          name: "credential_secret_provider_versions_version_source_id_fkey",
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

    create index(:credential_secret_provider_versions, [:version_source_id],
             prefix: @prefix,
             name: :credential_secret_provider_versions_source_idx
           )

    create table(:credential_broker_grants, primary_key: false, prefix: @prefix) do
      add(:id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)

      add(
        :secret_id,
        references(:network_credential_secrets,
          type: :uuid,
          on_delete: :restrict,
          prefix: @prefix
        )
      )

      add(:secret_ref, :text, null: false)
      add(:credential_rule_id, :uuid)
      add(:grant_type, :text, null: false)
      add(:consumer_kind, :text, null: false)
      add(:consumer_id, :text)
      add(:purpose, :text, null: false)
      add(:target_kind, :text)
      add(:target_id, :text)
      add(:agent_id, :text)
      add(:resolution_location, :text, null: false, default: "control_plane")
      add(:allowed_methods, {:array, :text}, null: false, default: [])
      add(:allowed_paths, {:array, :text}, null: false, default: [])
      add(:allowed_hosts, {:array, :text}, null: false, default: [])
      add(:allowed_ports, {:array, :integer}, null: false, default: [])
      add(:inject, :map, null: false, default: %{})
      add(:metadata, :map, null: false, default: %{})
      add(:ttl_seconds, :integer, null: false, default: 300)
      add(:expires_at, :utc_datetime_usec, null: false)
      add(:issued_by_actor_id, :text)
      add(:status, :text, null: false, default: "issued")
      add(:issued_at, :utc_datetime_usec)
      add(:consumed_at, :utc_datetime_usec)
      add(:denied_at, :utc_datetime_usec)
      add(:denial_reason, :text)
      add(:revoked_at, :utc_datetime_usec)
      add(:revocation_reason, :text)

      add(:inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )

      add(:updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )
    end

    create index(:credential_broker_grants, [:secret_id, :status],
             prefix: @prefix,
             name: :credential_broker_grants_secret_status_idx
           )

    create index(:credential_broker_grants, [:consumer_kind, :consumer_id],
             prefix: @prefix,
             name: :credential_broker_grants_consumer_idx
           )

    create index(:credential_broker_grants, [:agent_id, :status, :expires_at],
             prefix: @prefix,
             name: :credential_broker_grants_agent_status_expires_idx
           )

    create table(:credential_broker_grant_versions, primary_key: false, prefix: @prefix) do
      add(:id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:version_action_type, :text, null: false)
      add(:version_action_name, :text, null: false)
      add(:version_action_inputs, :map, null: false)

      add(
        :version_source_id,
        references(:credential_broker_grants,
          type: :uuid,
          name: "credential_broker_grant_versions_version_source_id_fkey",
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

    create index(:credential_broker_grant_versions, [:version_source_id],
             prefix: @prefix,
             name: :credential_broker_grant_versions_source_idx
           )

    alter table(:network_credential_secrets, prefix: @prefix) do
      add(:source_type, :text, null: false, default: "internal_encrypted")

      add(
        :secret_provider_id,
        references(:credential_secret_providers,
          type: :uuid,
          on_delete: :restrict,
          prefix: @prefix
        )
      )

      add(:external_secret_ref, :text)
      add(:external_secret_version, :text)
      add(:external_secret_fields, :map, null: false, default: %{})
      add(:resolution_location, :text)
      add(:cache_policy, :text, null: false, default: "no_cache")
      add(:cache_ttl_seconds, :integer)
      add(:rotation_state, :text, null: false, default: "active")
      add(:rotation_started_at, :utc_datetime_usec)
      add(:last_rotation_failed_at, :utc_datetime_usec)
      add(:last_rotation_failure_message, :text)
      add(:last_resolved_at, :utc_datetime_usec)
      add(:last_resolution_status, :text)
      add(:last_resolution_message, :text)
    end

    create index(:network_credential_secrets, [:source_type, :secret_provider_id],
             prefix: @prefix,
             name: :network_credential_secrets_source_provider_idx
           )

    create table(:credential_secret_resolution_audits, primary_key: false, prefix: @prefix) do
      add(:id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)

      add(
        :secret_id,
        references(:network_credential_secrets,
          type: :uuid,
          on_delete: :nilify_all,
          prefix: @prefix
        )
      )

      add(
        :secret_provider_id,
        references(:credential_secret_providers,
          type: :uuid,
          on_delete: :nilify_all,
          prefix: @prefix
        )
      )

      add(:grant_id, :text)
      add(:consumer_kind, :text, null: false)
      add(:consumer_id, :text)
      add(:purpose, :text)
      add(:target_kind, :text)
      add(:target_id, :text)
      add(:agent_id, :text)
      add(:resolution_location, :text, null: false)
      add(:outcome, :text, null: false)
      add(:error_class, :text)
      add(:cache_status, :text)
      add(:lease_expires_at, :utc_datetime_usec)
      add(:metadata, :map, null: false, default: %{})
      add(:occurred_at, :utc_datetime_usec, null: false)

      add(:inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )
    end

    create index(:credential_secret_resolution_audits, [:secret_id, :occurred_at],
             prefix: @prefix,
             name: :credential_secret_resolution_audits_secret_time_idx
           )

    create index(:credential_secret_resolution_audits, [:secret_provider_id, :occurred_at],
             prefix: @prefix,
             name: :credential_secret_resolution_audits_provider_time_idx
           )

    create index(:credential_secret_resolution_audits, [:consumer_kind, :consumer_id],
             prefix: @prefix,
             name: :credential_secret_resolution_audits_consumer_idx
           )

    create table(:credential_secret_resolution_audit_versions,
             primary_key: false,
             prefix: @prefix
           ) do
      add(:id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:version_action_type, :text, null: false)
      add(:version_action_name, :text, null: false)
      add(:version_action_inputs, :map, null: false)

      add(
        :version_source_id,
        references(:credential_secret_resolution_audits,
          type: :uuid,
          name: "credential_secret_resolution_audit_versions_version_source_id_fkey",
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

    create index(:credential_secret_resolution_audit_versions, [:version_source_id],
             prefix: @prefix,
             name: :credential_secret_resolution_audit_versions_source_idx
           )
  end
end
