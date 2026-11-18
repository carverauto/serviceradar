defmodule ServiceRadar.Repo.Migrations.CreateWebPropertiesAndBindings do
  @moduledoc """
  Creates L7 web property inventory (`platform.web_properties`),
  infrastructure bindings (`platform.web_property_bindings`),
  and links `platform.service_checks.web_property_id`.
  """

  use Ecto.Migration

  def up do
    execute("CREATE SCHEMA IF NOT EXISTS platform")

    create table(:web_properties, primary_key: false, prefix: "platform") do
      add(:id, :uuid, null: false, default: fragment("uuid_generate_v7()"), primary_key: true)
      add(:name, :text, null: false)
      add(:canonical_origin, :text, null: false)
      add(:allowed_origins, {:array, :text}, null: false, default: [])
      add(:allowed_query_keys, {:array, :text}, null: false, default: [])
      add(:trace_propagate_origins, {:array, :text}, null: false, default: [])
      add(:environment, :text, null: false, default: "production")
      add(:tags, :map, null: false, default: %{})
      add(:prefix_tags, {:array, :map}, null: false, default: [])
      add(:rum_enabled, :boolean, null: false, default: true)
      add(:rum_site_key, :text, null: false)
      add(:rum_sample_rate, :float, null: false, default: 1.0)
      add(:anonymize_client_ip, :boolean, null: false, default: true)
      add(:edge_provider, :text)
      add(:observed_vips, {:array, :text}, null: false, default: [])
      add(:observed_asns, {:array, :integer}, null: false, default: [])
      add(:tls_not_after, :utc_datetime_usec)
      add(:tls_issuer, :text)
      add(:last_posture_checked_at, :utc_datetime_usec)

      add(:created_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )

      add(:updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )
    end

    create(
      unique_index(:web_properties, [:canonical_origin],
        name: "web_properties_canonical_origin_index",
        prefix: "platform"
      )
    )

    create(
      unique_index(:web_properties, [:rum_site_key],
        name: "web_properties_rum_site_key_index",
        prefix: "platform"
      )
    )

    create(
      constraint(:web_properties, :web_properties_valid,
        check: """
        btrim(name) <> '' AND
        canonical_origin ~ '^https?://' AND
        environment IN ('production', 'staging', 'development', 'internal') AND
        rum_site_key ~ '^sr_rum_[A-Za-z0-9_-]{16,}$' AND
        rum_sample_rate >= 0.0 AND rum_sample_rate <= 1.0
        """,
        prefix: "platform"
      )
    )

    create table(:web_property_bindings, primary_key: false, prefix: "platform") do
      add(:id, :uuid, null: false, default: fragment("uuid_generate_v7()"), primary_key: true)

      add(
        :web_property_id,
        references(:web_properties,
          column: :id,
          name: "web_property_bindings_web_property_id_fkey",
          type: :uuid,
          prefix: "platform",
          on_delete: :delete_all
        ),
        null: false
      )

      add(:binding_kind, :text, null: false)
      add(:source, :text, null: false, default: "manual")
      add(:cluster_id, :text)
      add(:namespace, :text)
      add(:resource_kind, :text)
      add(:resource_name, :text)
      add(:endpoint_key, :text)

      add(
        :device_uid,
        references(:ocsf_devices,
          column: :uid,
          name: "web_property_bindings_device_uid_fkey",
          type: :text,
          prefix: "platform",
          on_delete: :delete_all
        )
      )

      add(:otel_service_name, :text)
      add(:metadata, :map, null: false, default: %{})
      add(:last_observed_at, :utc_datetime_usec)

      add(:created_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )

      add(:updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )
    end

    create(
      index(:web_property_bindings, [:web_property_id],
        name: "web_property_bindings_web_property_id_index",
        prefix: "platform"
      )
    )

    create(
      index(:web_property_bindings, [:device_uid],
        where: "device_uid IS NOT NULL",
        name: "web_property_bindings_device_uid_index",
        prefix: "platform"
      )
    )

    create(
      index(:web_property_bindings, [:endpoint_key],
        where: "endpoint_key IS NOT NULL",
        name: "web_property_bindings_endpoint_key_index",
        prefix: "platform"
      )
    )

    create(
      unique_index(
        :web_property_bindings,
        [:web_property_id, :cluster_id, :namespace, :resource_kind, :resource_name],
        where: "binding_kind = 'k8s_public_endpoint'",
        name: "web_property_bindings_k8s_unique_index",
        prefix: "platform"
      )
    )

    create(
      unique_index(:web_property_bindings, [:web_property_id, :device_uid],
        where: "binding_kind = 'origin_device' AND device_uid IS NOT NULL",
        name: "web_property_bindings_origin_device_unique_index",
        prefix: "platform"
      )
    )

    create(
      unique_index(:web_property_bindings, [:web_property_id, :otel_service_name],
        where: "binding_kind = 'otel_service' AND otel_service_name IS NOT NULL",
        name: "web_property_bindings_otel_service_unique_index",
        prefix: "platform"
      )
    )

    create(
      constraint(:web_property_bindings, :web_property_bindings_valid,
        check: """
        binding_kind IN ('k8s_public_endpoint', 'origin_device', 'otel_service') AND
        source IN ('manual', 'k8s_discovery', 'auto_vip_match', 'trace_correlation') AND
        (
          (binding_kind = 'k8s_public_endpoint' AND
           coalesce(btrim(cluster_id), '') <> '' AND
           namespace IS NOT NULL AND
           coalesce(btrim(resource_kind), '') <> '' AND
           coalesce(btrim(resource_name), '') <> '' AND
           device_uid IS NULL AND
           otel_service_name IS NULL)
          OR
          (binding_kind = 'origin_device' AND
           coalesce(btrim(device_uid), '') <> '' AND
           otel_service_name IS NULL)
          OR
          (binding_kind = 'otel_service' AND
           coalesce(btrim(otel_service_name), '') <> '' AND
           device_uid IS NULL)
        )
        """,
        prefix: "platform"
      )
    )

    alter table(:service_checks, prefix: "platform") do
      add(
        :web_property_id,
        references(:web_properties,
          column: :id,
          name: "service_checks_web_property_id_fkey",
          type: :uuid,
          prefix: "platform",
          on_delete: :nilify_all
        )
      )
    end

    create(
      index(:service_checks, [:web_property_id],
        where: "web_property_id IS NOT NULL",
        name: "service_checks_web_property_id_index",
        prefix: "platform"
      )
    )
  end

  def down do
    drop_if_exists(
      index(:service_checks, [:web_property_id],
        name: "service_checks_web_property_id_index",
        prefix: "platform"
      )
    )

    alter table(:service_checks, prefix: "platform") do
      remove(:web_property_id)
    end

    drop_if_exists(
      constraint(:web_property_bindings, :web_property_bindings_valid, prefix: "platform")
    )

    drop_if_exists(
      unique_index(:web_property_bindings, [:web_property_id, :otel_service_name],
        name: "web_property_bindings_otel_service_unique_index",
        prefix: "platform"
      )
    )

    drop_if_exists(
      unique_index(:web_property_bindings, [:web_property_id, :device_uid],
        name: "web_property_bindings_origin_device_unique_index",
        prefix: "platform"
      )
    )

    drop_if_exists(
      unique_index(
        :web_property_bindings,
        [:web_property_id, :cluster_id, :namespace, :resource_kind, :resource_name],
        name: "web_property_bindings_k8s_unique_index",
        prefix: "platform"
      )
    )

    drop_if_exists(
      index(:web_property_bindings, [:endpoint_key],
        name: "web_property_bindings_endpoint_key_index",
        prefix: "platform"
      )
    )

    drop_if_exists(
      index(:web_property_bindings, [:device_uid],
        name: "web_property_bindings_device_uid_index",
        prefix: "platform"
      )
    )

    drop_if_exists(
      index(:web_property_bindings, [:web_property_id],
        name: "web_property_bindings_web_property_id_index",
        prefix: "platform"
      )
    )

    drop(table(:web_property_bindings, prefix: "platform"))

    drop_if_exists(constraint(:web_properties, :web_properties_valid, prefix: "platform"))

    drop_if_exists(
      unique_index(:web_properties, [:rum_site_key],
        name: "web_properties_rum_site_key_index",
        prefix: "platform"
      )
    )

    drop_if_exists(
      unique_index(:web_properties, [:canonical_origin],
        name: "web_properties_canonical_origin_index",
        prefix: "platform"
      )
    )

    drop(table(:web_properties, prefix: "platform"))
  end
end
