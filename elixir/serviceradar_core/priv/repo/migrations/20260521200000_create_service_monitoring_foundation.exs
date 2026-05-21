defmodule ServiceRadar.Repo.Migrations.CreateServiceMonitoringFoundation do
  @moduledoc false
  use Ecto.Migration

  @prefix "platform"

  def change do
    create table(:monitored_services, primary_key: false, prefix: @prefix) do
      add(:id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:service_key, :text, null: false)
      add(:display_name, :text, null: false)
      add(:description, :text)
      add(:service_kind, :text, null: false)
      add(:protocol, :text)
      add(:endpoint_url, :text)
      add(:host, :text)
      add(:port, :bigint)
      add(:path, :text)

      add(
        :device_uid,
        references(:ocsf_devices,
          column: :uid,
          type: :text,
          on_delete: :nilify_all,
          prefix: @prefix
        )
      )

      add(:database_name, :text)
      add(:owner, :text)
      add(:status, :text, null: false, default: "active")
      add(:source, :text, null: false, default: "manual")
      add(:tags, :map, null: false, default: %{})
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

    create unique_index(:monitored_services, [:service_key],
             prefix: @prefix,
             name: :monitored_services_service_key_idx
           )

    create index(:monitored_services, [:service_kind, :status],
             prefix: @prefix,
             name: :monitored_services_kind_status_idx
           )

    create index(:monitored_services, [:device_uid],
             prefix: @prefix,
             name: :monitored_services_device_uid_idx
           )

    create index(:monitored_services, [:tags],
             prefix: @prefix,
             name: :monitored_services_tags_idx,
             using: :gin
           )

    create_version_table(
      :monitored_service_versions,
      :monitored_services,
      "monitored_service_versions_version_source_id_fkey",
      :monitored_service_versions_source_idx
    )

    create table(:service_groups, primary_key: false, prefix: @prefix) do
      add(:id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:name, :text, null: false)
      add(:slug, :text, null: false)
      add(:description, :text)
      add(:selection_mode, :text, null: false, default: "explicit")
      add(:srql_query, :text)
      add(:status, :text, null: false, default: "active")
      add(:tags, :map, null: false, default: %{})
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

    create unique_index(:service_groups, [:slug], prefix: @prefix, name: :service_groups_slug_idx)
    create index(:service_groups, [:status], prefix: @prefix, name: :service_groups_status_idx)

    create_version_table(
      :service_group_versions,
      :service_groups,
      "service_group_versions_version_source_id_fkey",
      :service_group_versions_source_idx
    )

    create table(:service_group_memberships, primary_key: false, prefix: @prefix) do
      add(:id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)

      add(
        :service_group_id,
        references(:service_groups, type: :uuid, on_delete: :delete_all, prefix: @prefix),
        null: false
      )

      add(
        :monitored_service_id,
        references(:monitored_services, type: :uuid, on_delete: :delete_all, prefix: @prefix),
        null: false
      )

      add(:source, :text, null: false, default: "explicit")
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

    create unique_index(:service_group_memberships, [:service_group_id, :monitored_service_id],
             prefix: @prefix,
             name: :service_group_memberships_group_service_idx
           )

    create index(:service_group_memberships, [:monitored_service_id],
             prefix: @prefix,
             name: :service_group_memberships_service_idx
           )

    create_version_table(
      :service_group_membership_versions,
      :service_group_memberships,
      "service_group_membership_versions_version_source_id_fkey",
      :service_group_membership_versions_source_idx
    )

    create table(:monitoring_bindings, primary_key: false, prefix: @prefix) do
      add(:id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:name, :text, null: false)
      add(:description, :text)
      add(:descriptor_id, :text, null: false)
      add(:descriptor_version, :text, null: false, default: "1.0.0")
      add(:capability_kind, :text, null: false, default: "plugin")

      add(
        :plugin_package_id,
        references(:plugin_packages, type: :uuid, on_delete: :nilify_all, prefix: @prefix)
      )

      add(:target_set_type, :text, null: false)

      add(
        :service_group_id,
        references(:service_groups, type: :uuid, on_delete: :nilify_all, prefix: @prefix)
      )

      add(:target_query, :text)
      add(:target_filters, :map, null: false, default: %{})
      add(:agent_scope_type, :text, null: false, default: "any")
      add(:agent_scope_value, :text)
      add(:interval_seconds, :bigint, null: false, default: 60)
      add(:timeout_seconds, :bigint, null: false, default: 10)
      add(:credential_policy, :map, null: false, default: %{})
      add(:threshold_policy, :map, null: false, default: %{})
      add(:event_policy, :map, null: false, default: %{})
      add(:alert_policy, :map, null: false, default: %{})
      add(:status, :text, null: false, default: "draft")
      add(:last_reconciled_at, :utc_datetime_usec)
      add(:last_reconcile_summary, :map, null: false, default: %{})
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

    create index(:monitoring_bindings, [:descriptor_id, :descriptor_version],
             prefix: @prefix,
             name: :monitoring_bindings_descriptor_idx
           )

    create index(:monitoring_bindings, [:plugin_package_id],
             prefix: @prefix,
             name: :monitoring_bindings_plugin_package_idx
           )

    create index(:monitoring_bindings, [:service_group_id],
             prefix: @prefix,
             name: :monitoring_bindings_service_group_idx
           )

    create index(:monitoring_bindings, [:status],
             prefix: @prefix,
             name: :monitoring_bindings_status_idx
           )

    create_version_table(
      :monitoring_binding_versions,
      :monitoring_bindings,
      "monitoring_binding_versions_version_source_id_fkey",
      :monitoring_binding_versions_source_idx
    )

    create table(:check_instances, primary_key: false, prefix: @prefix) do
      add(:id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:check_key, :text, null: false)

      add(
        :monitoring_binding_id,
        references(:monitoring_bindings, type: :uuid, on_delete: :nilify_all, prefix: @prefix)
      )

      add(
        :monitored_service_id,
        references(:monitored_services, type: :uuid, on_delete: :nilify_all, prefix: @prefix)
      )

      add(
        :device_uid,
        references(:ocsf_devices,
          column: :uid,
          type: :text,
          on_delete: :nilify_all,
          prefix: @prefix
        )
      )

      add(:descriptor_id, :text, null: false)
      add(:descriptor_version, :text, null: false, default: "1.0.0")
      add(:capability_kind, :text, null: false, default: "plugin")

      add(
        :plugin_package_id,
        references(:plugin_packages, type: :uuid, on_delete: :nilify_all, prefix: @prefix)
      )

      add(:vantage_kind, :text, null: false, default: "agent")
      add(:vantage_id, :text)

      add(
        :agent_id,
        references(:ocsf_agents,
          column: :uid,
          type: :text,
          on_delete: :nilify_all,
          prefix: @prefix
        )
      )

      add(:target_snapshot, :map, null: false, default: %{})
      add(:credential_policy_snapshot, :map, null: false, default: %{})
      add(:event_policy_snapshot, :map, null: false, default: %{})
      add(:status, :text, null: false, default: "active")
      add(:last_materialized_at, :utc_datetime_usec)
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

    create unique_index(:check_instances, [:check_key],
             prefix: @prefix,
             name: :check_instances_check_key_idx
           )

    create index(:check_instances, [:monitoring_binding_id, :status],
             prefix: @prefix,
             name: :check_instances_binding_status_idx
           )

    create index(:check_instances, [:monitored_service_id, :status],
             prefix: @prefix,
             name: :check_instances_service_status_idx
           )

    create index(:check_instances, [:agent_id, :status],
             prefix: @prefix,
             name: :check_instances_agent_status_idx
           )

    create_version_table(
      :check_instance_versions,
      :check_instances,
      "check_instance_versions_version_source_id_fkey",
      :check_instance_versions_source_idx
    )

    create table(:latest_check_states, primary_key: false, prefix: @prefix) do
      add(:id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)

      add(
        :check_instance_id,
        references(:check_instances, type: :uuid, on_delete: :delete_all, prefix: @prefix),
        null: false
      )

      add(
        :monitored_service_id,
        references(:monitored_services, type: :uuid, on_delete: :nilify_all, prefix: @prefix)
      )

      add(
        :monitoring_binding_id,
        references(:monitoring_bindings, type: :uuid, on_delete: :nilify_all, prefix: @prefix)
      )

      add(
        :device_uid,
        references(:ocsf_devices,
          column: :uid,
          type: :text,
          on_delete: :nilify_all,
          prefix: @prefix
        )
      )

      add(
        :agent_id,
        references(:ocsf_agents,
          column: :uid,
          type: :text,
          on_delete: :nilify_all,
          prefix: @prefix
        )
      )

      add(:vantage_kind, :text, null: false, default: "agent")
      add(:vantage_id, :text)
      add(:status, :text, null: false, default: "unknown")
      add(:previous_status, :text)
      add(:status_changed_at, :utc_datetime_usec)
      add(:last_observed_at, :utc_datetime_usec, null: false)
      add(:response_time_ms, :bigint)
      add(:summary, :text)
      add(:details, :map, null: false, default: %{})
      add(:metrics, :map, null: false, default: %{})
      add(:consecutive_failures, :bigint, null: false, default: 0)
      add(:event_emitted_at, :utc_datetime_usec)
      add(:alert_id, references(:alerts, type: :uuid, on_delete: :nilify_all, prefix: @prefix))

      add(:inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )

      add(:updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )
    end

    create unique_index(:latest_check_states, [:check_instance_id],
             prefix: @prefix,
             name: :latest_check_states_check_instance_idx
           )

    create index(:latest_check_states, [:monitored_service_id, :status],
             prefix: @prefix,
             name: :latest_check_states_service_status_idx
           )

    create index(:latest_check_states, [:monitoring_binding_id, :status],
             prefix: @prefix,
             name: :latest_check_states_binding_status_idx
           )

    create index(:latest_check_states, [:last_observed_at],
             prefix: @prefix,
             name: :latest_check_states_last_observed_idx
           )

    create table(:monitored_service_import_batches, primary_key: false, prefix: @prefix) do
      add(:id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:source_type, :text, null: false, default: "csv_upload")
      add(:status, :text, null: false, default: "draft")
      add(:filename, :text)
      add(:total_rows, :bigint, null: false, default: 0)
      add(:valid_rows, :bigint, null: false, default: 0)
      add(:invalid_rows, :bigint, null: false, default: 0)
      add(:duplicate_rows, :bigint, null: false, default: 0)
      add(:created_by_actor_id, :text)
      add(:validation_errors, :map, null: false, default: %{})
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

    create index(:monitored_service_import_batches, [:status],
             prefix: @prefix,
             name: :monitored_service_import_batches_status_idx
           )

    create_version_table(
      :monitored_service_import_batch_versions,
      :monitored_service_import_batches,
      "monitored_service_import_batch_versions_version_source_id_fkey",
      :monitored_service_import_batch_versions_source_idx
    )
  end

  defp create_version_table(version_table, source_table, foreign_key_name, index_name) do
    create table(version_table, primary_key: false, prefix: @prefix) do
      add(:id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:version_action_type, :text, null: false)
      add(:version_action_name, :text, null: false)
      add(:version_action_inputs, :map, null: false)

      add(
        :version_source_id,
        references(source_table, type: :uuid, name: foreign_key_name, prefix: @prefix),
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

    create index(version_table, [:version_source_id], prefix: @prefix, name: index_name)
  end
end
