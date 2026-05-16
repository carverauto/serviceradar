defmodule ServiceRadar.Repo.Migrations.CreateNorthboundActionTables do
  @moduledoc """
  Creates provider-neutral northbound action resources.

  The tables live in the `platform` schema and use AshPaperTrail-compatible
  version tables for provider, descriptor, invocation, and event-handler audit.
  """

  use Ecto.Migration

  @prefix "platform"

  def up do
    create table(:northbound_action_providers, primary_key: false, prefix: @prefix) do
      add(:id, :uuid, null: false, default: fragment("uuid_generate_v7()"), primary_key: true)
      add(:name, :text, null: false)
      add(:description, :text)
      add(:provider_type, :text, null: false)
      add(:source_ref, :text)

      add(
        :plugin_package_id,
        references(:plugin_packages, type: :uuid, on_delete: :nilify_all, prefix: @prefix)
      )

      add(:status, :text, null: false, default: "staged")
      add(:health_status, :text, null: false, default: "unknown")
      add(:last_health_at, :utc_datetime_usec)
      add(:last_health_summary, :text)
      add(:approved_capabilities, {:array, :text}, null: false, default: [])
      add(:credential_requirements, :map, null: false, default: %{})
      add(:metadata, :map, null: false, default: %{})
      add(:inserted_at, :utc_datetime_usec, null: false, default: fragment("now()"))
      add(:updated_at, :utc_datetime_usec, null: false, default: fragment("now()"))
    end

    create(index(:northbound_action_providers, [:status], prefix: @prefix))
    create(index(:northbound_action_providers, [:provider_type], prefix: @prefix))

    create(
      unique_index(:northbound_action_providers, [:provider_type, :source_ref],
        name: :northbound_action_providers_type_source_uidx,
        prefix: @prefix,
        where: "source_ref IS NOT NULL"
      )
    )

    create_version_table(:northbound_action_provider_versions, :northbound_action_providers)

    create table(:northbound_action_descriptors, primary_key: false, prefix: @prefix) do
      add(:id, :uuid, null: false, default: fragment("uuid_generate_v7()"), primary_key: true)

      add(
        :provider_id,
        references(:northbound_action_providers,
          type: :uuid,
          on_delete: :delete_all,
          prefix: @prefix
        ),
        null: false
      )

      add(:action_id, :text, null: false)
      add(:version, :text, null: false, default: "1.0.0")
      add(:label, :text, null: false)
      add(:description, :text)
      add(:scopes, {:array, :text}, null: false, default: [])
      add(:required_context, {:array, :text}, null: false, default: [])
      add(:input_schema, :map, null: false, default: %{})
      add(:safety_classification, :text, null: false, default: "standard")
      add(:requires_confirmation, :boolean, null: false, default: false)
      add(:timeout_seconds, :integer, null: false, default: 60)
      add(:credential_requirements, :map, null: false, default: %{})

      add(:result_schema_version, :text,
        null: false,
        default: "serviceradar.northbound_action_result.v1"
      )

      add(:descriptor_hash, :text)
      add(:enabled, :boolean, null: false, default: true)
      add(:metadata, :map, null: false, default: %{})
      add(:inserted_at, :utc_datetime_usec, null: false, default: fragment("now()"))
      add(:updated_at, :utc_datetime_usec, null: false, default: fragment("now()"))
    end

    create(
      unique_index(:northbound_action_descriptors, [:provider_id, :action_id, :version],
        name: :northbound_action_descriptors_provider_action_version_uidx,
        prefix: @prefix
      )
    )

    create(
      constraint(:northbound_action_descriptors, :northbound_action_descriptors_scopes_nonempty,
        check: "cardinality(scopes) > 0",
        prefix: @prefix
      )
    )

    execute(
      "CREATE INDEX northbound_action_descriptors_scopes_gin_idx ON #{@prefix}.northbound_action_descriptors USING GIN (scopes)"
    )

    create_version_table(:northbound_action_descriptor_versions, :northbound_action_descriptors)

    create table(:northbound_action_event_handlers, primary_key: false, prefix: @prefix) do
      add(:id, :uuid, null: false, default: fragment("uuid_generate_v7()"), primary_key: true)
      add(:name, :text, null: false)
      add(:description, :text)
      add(:state, :text, null: false, default: "disabled")

      add(
        :descriptor_id,
        references(:northbound_action_descriptors,
          type: :uuid,
          on_delete: :restrict,
          prefix: @prefix
        ),
        null: false
      )

      add(:match_expression, :map, null: false, default: %{})
      add(:target_resolver, :map, null: false, default: %{})
      add(:input_template, :map, null: false, default: %{})
      add(:dedupe_key_template, :text)
      add(:cooldown_seconds, :integer, null: false, default: 300)
      add(:rate_limit, :map, null: false, default: %{})
      add(:approval_mode, :text, null: false, default: "manual")
      add(:service_principal, :text, null: false, default: "northbound-event-handler")
      add(:last_triggered_at, :utc_datetime_usec)
      add(:metadata, :map, null: false, default: %{})
      add(:inserted_at, :utc_datetime_usec, null: false, default: fragment("now()"))
      add(:updated_at, :utc_datetime_usec, null: false, default: fragment("now()"))
    end

    create(index(:northbound_action_event_handlers, [:state], prefix: @prefix))
    create(index(:northbound_action_event_handlers, [:descriptor_id], prefix: @prefix))

    create_version_table(
      :northbound_action_event_handler_versions,
      :northbound_action_event_handlers
    )

    create table(:northbound_action_invocations, primary_key: false, prefix: @prefix) do
      add(:id, :uuid, null: false, default: fragment("uuid_generate_v7()"), primary_key: true)

      add(
        :provider_id,
        references(:northbound_action_providers,
          type: :uuid,
          on_delete: :nilify_all,
          prefix: @prefix
        )
      )

      add(
        :descriptor_id,
        references(:northbound_action_descriptors,
          type: :uuid,
          on_delete: :nilify_all,
          prefix: @prefix
        )
      )

      add(:action_id, :text, null: false)
      add(:action_version, :text, null: false, default: "1.0.0")
      add(:descriptor_hash, :text)
      add(:source, :text, null: false, default: "user")
      add(:requested_by_actor_id, :uuid)

      add(
        :event_handler_id,
        references(:northbound_action_event_handlers,
          type: :uuid,
          on_delete: :nilify_all,
          prefix: @prefix
        )
      )

      add(:originating_event_id, :text)
      add(:target_snapshots, {:array, :map}, null: false, default: [])
      add(:input_values, :map, null: false, default: %{})
      add(:redacted_input_values, :map, null: false, default: %{})
      add(:state, :text, null: false, default: "pending")
      add(:started_at, :utc_datetime_usec)
      add(:completed_at, :utc_datetime_usec)
      add(:result_summary, :map, null: false, default: %{})
      add(:external_correlation_id, :text)
      add(:error_class, :text)
      add(:error_message, :text)
      add(:metadata, :map, null: false, default: %{})
      add(:inserted_at, :utc_datetime_usec, null: false, default: fragment("now()"))
      add(:updated_at, :utc_datetime_usec, null: false, default: fragment("now()"))
    end

    create(index(:northbound_action_invocations, [:state, :inserted_at], prefix: @prefix))
    create(index(:northbound_action_invocations, [:action_id, :inserted_at], prefix: @prefix))
    create(index(:northbound_action_invocations, [:requested_by_actor_id], prefix: @prefix))
    create_version_table(:northbound_action_invocation_versions, :northbound_action_invocations)

    create table(:northbound_action_invocation_targets, primary_key: false, prefix: @prefix) do
      add(:id, :uuid, null: false, default: fragment("uuid_generate_v7()"), primary_key: true)

      add(
        :invocation_id,
        references(:northbound_action_invocations,
          type: :uuid,
          on_delete: :delete_all,
          prefix: @prefix
        ),
        null: false
      )

      add(:target_kind, :text, null: false)
      add(:device_uid, :text)
      add(:interface_uid, :text)
      add(:target_snapshot, :map, null: false, default: %{})
      add(:status, :text, null: false, default: "pending")
      add(:result, :map, null: false, default: %{})
      add(:external_correlation_id, :text)
      add(:started_at, :utc_datetime_usec)
      add(:completed_at, :utc_datetime_usec)
      add(:inserted_at, :utc_datetime_usec, null: false, default: fragment("now()"))
      add(:updated_at, :utc_datetime_usec, null: false, default: fragment("now()"))
    end

    create(index(:northbound_action_invocation_targets, [:invocation_id], prefix: @prefix))
    create(index(:northbound_action_invocation_targets, [:device_uid], prefix: @prefix))
    create(index(:northbound_action_invocation_targets, [:interface_uid], prefix: @prefix))
  end

  def down do
    execute("DROP INDEX IF EXISTS #{@prefix}.northbound_action_descriptors_scopes_gin_idx")

    drop_if_exists(table(:northbound_action_invocation_targets, prefix: @prefix))
    drop_if_exists(table(:northbound_action_invocation_versions, prefix: @prefix))
    drop_if_exists(table(:northbound_action_invocations, prefix: @prefix))
    drop_if_exists(table(:northbound_action_event_handler_versions, prefix: @prefix))
    drop_if_exists(table(:northbound_action_event_handlers, prefix: @prefix))
    drop_if_exists(table(:northbound_action_descriptor_versions, prefix: @prefix))
    drop_if_exists(table(:northbound_action_descriptors, prefix: @prefix))
    drop_if_exists(table(:northbound_action_provider_versions, prefix: @prefix))
    drop_if_exists(table(:northbound_action_providers, prefix: @prefix))
  end

  defp create_version_table(version_table, source_table) do
    create table(version_table, primary_key: false, prefix: @prefix) do
      add(:id, :uuid, null: false, default: fragment("uuid_generate_v7()"), primary_key: true)
      add(:version_action_type, :text, null: false)
      add(:version_action_name, :text, null: false)
      add(:version_action_inputs, :map, null: false, default: %{})

      add(
        :version_source_id,
        references(source_table, type: :uuid, on_delete: :delete_all, prefix: @prefix),
        null: false
      )

      add(:changes, :map, null: false, default: %{})
      add(:version_inserted_at, :utc_datetime_usec, null: false, default: fragment("now()"))
      add(:version_updated_at, :utc_datetime_usec, null: false, default: fragment("now()"))
    end

    create(index(version_table, [:version_source_id], prefix: @prefix))
  end
end
