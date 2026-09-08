defmodule ServiceRadar.Repo.Migrations.CreateWifiMapTables do
  @moduledoc false
  use Ecto.Migration

  @prefix "platform"

  def up do
    execute("CREATE EXTENSION IF NOT EXISTS postgis;")

    create table(:wifi_map_sources, primary_key: false, prefix: @prefix) do
      add(:source_id, :uuid, null: false, default: fragment("gen_random_uuid()"))
      add(:plugin_source_id, :uuid)
      add(:name, :text, null: false)
      add(:source_kind, :text, null: false)
      add(:latest_collection_at, :timestamptz)
      add(:latest_reference_hash, :text)
      add(:latest_reference_at, :timestamptz)
      add(:metadata, :map, null: false, default: %{})
      add(:inserted_at, :timestamptz, null: false)
      add(:updated_at, :timestamptz, null: false)
    end

    execute("ALTER TABLE #{@prefix}.wifi_map_sources ADD PRIMARY KEY (source_id);")

    create(
      unique_index(:wifi_map_sources, [:name],
        prefix: @prefix,
        name: :wifi_map_sources_unique_name_idx
      )
    )

    create(
      index(:wifi_map_sources, [:source_kind],
        prefix: @prefix,
        name: :wifi_map_sources_kind_idx
      )
    )

    create table(:wifi_map_batches, primary_key: false, prefix: @prefix) do
      add(:batch_id, :uuid, null: false, default: fragment("gen_random_uuid()"))

      add(
        :source_id,
        references(:wifi_map_sources,
          column: :source_id,
          type: :uuid,
          prefix: @prefix,
          on_delete: :delete_all
        ),
        null: false
      )

      add(:collection_mode, :text, null: false)
      add(:collection_timestamp, :timestamptz, null: false)
      add(:reference_hash, :text)
      add(:source_files, :map, null: false, default: %{})
      add(:row_counts, :map, null: false, default: %{})
      add(:diagnostics, :map, null: false, default: %{})
      add(:inserted_at, :timestamptz, null: false)
    end

    execute("ALTER TABLE #{@prefix}.wifi_map_batches ADD PRIMARY KEY (batch_id);")

    create(
      index(:wifi_map_batches, [:source_id, :collection_timestamp],
        prefix: @prefix,
        name: :wifi_map_batches_source_time_idx
      )
    )

    create(
      unique_index(:wifi_map_batches, [:source_id, :collection_timestamp, :collection_mode],
        prefix: @prefix,
        name: :wifi_map_batches_source_time_mode_idx
      )
    )

    create table(:wifi_site_references, primary_key: false, prefix: @prefix) do
      add(
        :source_id,
        references(:wifi_map_sources,
          column: :source_id,
          type: :uuid,
          prefix: @prefix,
          on_delete: :delete_all
        ),
        null: false
      )

      add(:site_code, :text, null: false)
      add(:name, :text, null: false)
      add(:site_type, :text, null: false)
      add(:region, :text)
      add(:latitude, :float)
      add(:longitude, :float)
      add(:reference_hash, :text)
      add(:reference_metadata, :map, null: false, default: %{})
      add(:updated_at, :timestamptz, null: false)
    end

    execute("ALTER TABLE #{@prefix}.wifi_site_references ADD PRIMARY KEY (source_id, site_code);")
    add_location_column(:wifi_site_references)
    add_coordinate_constraints(:wifi_site_references)

    create(
      index(:wifi_site_references, [:site_code],
        prefix: @prefix,
        name: :wifi_site_references_site_code_idx
      )
    )

    create(
      index(:wifi_site_references, [:site_type, :region],
        prefix: @prefix,
        name: :wifi_site_references_type_region_idx
      )
    )

    create_gist_index(:wifi_site_references, :location)

    create table(:wifi_sites, primary_key: false, prefix: @prefix) do
      add(
        :source_id,
        references(:wifi_map_sources,
          column: :source_id,
          type: :uuid,
          prefix: @prefix,
          on_delete: :delete_all
        ),
        null: false
      )

      add(:site_code, :text, null: false)
      add(:name, :text, null: false)
      add(:site_type, :text, null: false)
      add(:region, :text)
      add(:latitude, :float)
      add(:longitude, :float)
      add(:metadata, :map, null: false, default: %{})
      add(:first_seen_at, :timestamptz)
      add(:last_seen_at, :timestamptz)
      add(:inserted_at, :timestamptz, null: false)
      add(:updated_at, :timestamptz, null: false)
    end

    execute("ALTER TABLE #{@prefix}.wifi_sites ADD PRIMARY KEY (source_id, site_code);")
    add_location_column(:wifi_sites)
    add_coordinate_constraints(:wifi_sites)

    create(
      index(:wifi_sites, [:site_code],
        prefix: @prefix,
        name: :wifi_sites_site_code_idx
      )
    )

    create(
      index(:wifi_sites, [:site_type, :region],
        prefix: @prefix,
        name: :wifi_sites_type_region_idx
      )
    )

    create_gist_index(:wifi_sites, :location)

    create table(:wifi_site_snapshots, primary_key: false, prefix: @prefix) do
      add(:id, :uuid, null: false, default: fragment("gen_random_uuid()"))

      add(
        :source_id,
        references(:wifi_map_sources,
          column: :source_id,
          type: :uuid,
          prefix: @prefix,
          on_delete: :delete_all
        ),
        null: false
      )

      add(
        :batch_id,
        references(:wifi_map_batches,
          column: :batch_id,
          type: :uuid,
          prefix: @prefix,
          on_delete: :nilify_all
        )
      )

      add(:site_code, :text, null: false)
      add(:collection_timestamp, :timestamptz, null: false)
      add(:ap_count, :integer, null: false, default: 0)
      add(:up_count, :integer, null: false, default: 0)
      add(:down_count, :integer, null: false, default: 0)
      add(:model_breakdown, :map, null: false, default: %{})
      add(:controller_names, {:array, :text}, null: false, default: [])
      add(:wlc_count, :integer, null: false, default: 0)
      add(:wlc_model_breakdown, :map, null: false, default: %{})
      add(:aos_version_breakdown, :map, null: false, default: %{})
      add(:server_group, :text)
      add(:cluster, :text)
      add(:all_server_groups, {:array, :text}, null: false, default: [])
      add(:aaa_profile, :text)
      add(:metadata, :map, null: false, default: %{})
      add(:inserted_at, :timestamptz, null: false)
      add(:updated_at, :timestamptz, null: false)
    end

    execute("ALTER TABLE #{@prefix}.wifi_site_snapshots ADD PRIMARY KEY (id);")

    create(
      unique_index(:wifi_site_snapshots, [:source_id, :site_code, :collection_timestamp],
        prefix: @prefix,
        name: :wifi_site_snapshots_source_site_time_idx
      )
    )

    create(
      index(:wifi_site_snapshots, [:source_id, :collection_timestamp],
        prefix: @prefix,
        name: :wifi_site_snapshots_source_time_idx
      )
    )

    create(
      index(:wifi_site_snapshots, [:source_id, :cluster, :collection_timestamp],
        prefix: @prefix,
        name: :wifi_site_snapshots_cluster_time_idx
      )
    )

    create table(:wifi_access_point_observations, primary_key: false, prefix: @prefix) do
      add(:id, :uuid, null: false, default: fragment("gen_random_uuid()"))

      add(
        :source_id,
        references(:wifi_map_sources,
          column: :source_id,
          type: :uuid,
          prefix: @prefix,
          on_delete: :delete_all
        ),
        null: false
      )

      add(
        :batch_id,
        references(:wifi_map_batches,
          column: :batch_id,
          type: :uuid,
          prefix: @prefix,
          on_delete: :nilify_all
        )
      )

      add(:device_uid, :text)
      add(:site_code, :text, null: false)
      add(:collection_timestamp, :timestamptz, null: false)
      add(:name, :text)
      add(:hostname, :text)
      add(:mac, :text)
      add(:serial, :text)
      add(:ip, :text)
      add(:status, :text)
      add(:model, :text)
      add(:vendor_name, :text)
      add(:metadata, :map, null: false, default: %{})
      add(:inserted_at, :timestamptz, null: false)
      add(:updated_at, :timestamptz, null: false)
    end

    execute("ALTER TABLE #{@prefix}.wifi_access_point_observations ADD PRIMARY KEY (id);")

    create(
      unique_index(:wifi_access_point_observations, [:source_id, :collection_timestamp, :name],
        prefix: @prefix,
        name: :wifi_ap_observations_source_time_name_idx
      )
    )

    create(
      index(:wifi_access_point_observations, [:source_id, :site_code, :collection_timestamp],
        prefix: @prefix,
        name: :wifi_ap_observations_source_site_time_idx
      )
    )

    create(
      index(:wifi_access_point_observations, [:device_uid, :collection_timestamp],
        prefix: @prefix,
        name: :wifi_ap_observations_device_time_idx
      )
    )

    create(
      index(:wifi_access_point_observations, [:source_id, :status, :collection_timestamp],
        prefix: @prefix,
        name: :wifi_ap_observations_status_time_idx
      )
    )

    create table(:wifi_controller_observations, primary_key: false, prefix: @prefix) do
      add(:id, :uuid, null: false, default: fragment("gen_random_uuid()"))

      add(
        :source_id,
        references(:wifi_map_sources,
          column: :source_id,
          type: :uuid,
          prefix: @prefix,
          on_delete: :delete_all
        ),
        null: false
      )

      add(
        :batch_id,
        references(:wifi_map_batches,
          column: :batch_id,
          type: :uuid,
          prefix: @prefix,
          on_delete: :nilify_all
        )
      )

      add(:device_uid, :text)
      add(:site_code, :text, null: false)
      add(:collection_timestamp, :timestamptz, null: false)
      add(:name, :text)
      add(:hostname, :text)
      add(:ip, :text)
      add(:mac, :text)
      add(:base_mac, :text)
      add(:serial, :text)
      add(:model, :text)
      add(:aos_version, :text)
      add(:psu_status, :text)
      add(:uptime, :text)
      add(:reboot_cause, :text)
      add(:metadata, :map, null: false, default: %{})
      add(:inserted_at, :timestamptz, null: false)
      add(:updated_at, :timestamptz, null: false)
    end

    execute("ALTER TABLE #{@prefix}.wifi_controller_observations ADD PRIMARY KEY (id);")

    create(
      unique_index(:wifi_controller_observations, [:source_id, :collection_timestamp, :name],
        prefix: @prefix,
        name: :wifi_controller_observations_source_time_name_idx
      )
    )

    create(
      index(:wifi_controller_observations, [:source_id, :site_code, :collection_timestamp],
        prefix: @prefix,
        name: :wifi_controller_observations_site_time_idx
      )
    )

    create(
      index(:wifi_controller_observations, [:device_uid, :collection_timestamp],
        prefix: @prefix,
        name: :wifi_controller_observations_device_time_idx
      )
    )

    create(
      index(:wifi_controller_observations, [:source_id, :aos_version],
        prefix: @prefix,
        name: :wifi_controller_observations_aos_version_idx
      )
    )

    create table(:wifi_radius_group_observations, primary_key: false, prefix: @prefix) do
      add(:id, :uuid, null: false, default: fragment("gen_random_uuid()"))

      add(
        :source_id,
        references(:wifi_map_sources,
          column: :source_id,
          type: :uuid,
          prefix: @prefix,
          on_delete: :delete_all
        ),
        null: false
      )

      add(
        :batch_id,
        references(:wifi_map_batches,
          column: :batch_id,
          type: :uuid,
          prefix: @prefix,
          on_delete: :nilify_all
        )
      )

      add(:controller_device_uid, :text)
      add(:site_code, :text, null: false)
      add(:collection_timestamp, :timestamptz, null: false)
      add(:controller_alias, :text)
      add(:aaa_profile, :text)
      add(:server_group, :text)
      add(:cluster, :text)
      add(:all_server_groups, {:array, :text}, null: false, default: [])
      add(:status, :text)
      add(:metadata, :map, null: false, default: %{})
      add(:inserted_at, :timestamptz, null: false)
      add(:updated_at, :timestamptz, null: false)
    end

    execute("ALTER TABLE #{@prefix}.wifi_radius_group_observations ADD PRIMARY KEY (id);")

    create(
      unique_index(
        :wifi_radius_group_observations,
        [:source_id, :site_code, :controller_alias, :aaa_profile, :collection_timestamp],
        prefix: @prefix,
        name: :wifi_radius_groups_source_site_controller_profile_time_idx
      )
    )

    create(
      index(:wifi_radius_group_observations, [:source_id, :cluster, :collection_timestamp],
        prefix: @prefix,
        name: :wifi_radius_groups_cluster_time_idx
      )
    )

    create table(:wifi_fleet_history, primary_key: false, prefix: @prefix) do
      add(
        :source_id,
        references(:wifi_map_sources,
          column: :source_id,
          type: :uuid,
          prefix: @prefix,
          on_delete: :delete_all
        ),
        null: false
      )

      add(
        :batch_id,
        references(:wifi_map_batches,
          column: :batch_id,
          type: :uuid,
          prefix: @prefix,
          on_delete: :nilify_all
        )
      )

      add(:build_date, :date, null: false)
      add(:ap_total, :integer, null: false, default: 0)
      add(:count_2xx, :integer, null: false, default: 0)
      add(:count_3xx, :integer, null: false, default: 0)
      add(:count_4xx, :integer, null: false, default: 0)
      add(:count_5xx, :integer, null: false, default: 0)
      add(:count_6xx, :integer, null: false, default: 0)
      add(:count_7xx, :integer, null: false, default: 0)
      add(:count_other, :integer, null: false, default: 0)
      add(:count_ap325, :integer)
      add(:pct_6xx, :float)
      add(:pct_legacy, :float)
      add(:site_count, :integer, null: false, default: 0)
      add(:metadata, :map, null: false, default: %{})
      add(:inserted_at, :timestamptz, null: false)
      add(:updated_at, :timestamptz, null: false)
    end

    execute("ALTER TABLE #{@prefix}.wifi_fleet_history ADD PRIMARY KEY (source_id, build_date);")

    create(
      index(:wifi_fleet_history, [:build_date],
        prefix: @prefix,
        name: :wifi_fleet_history_build_date_idx
      )
    )

    create table(:wifi_map_views, primary_key: false, prefix: @prefix) do
      add(:id, :uuid, null: false, default: fragment("gen_random_uuid()"))
      add(:name, :text, null: false)
      add(:description, :text)
      add(:srql_query, :text, null: false)
      add(:is_default_dashboard, :boolean, null: false, default: false)
      add(:visualization_options, :map, null: false, default: %{})
      add(:inserted_at, :timestamptz, null: false)
      add(:updated_at, :timestamptz, null: false)
    end

    execute("ALTER TABLE #{@prefix}.wifi_map_views ADD PRIMARY KEY (id);")

    create(
      unique_index(:wifi_map_views, [:name],
        prefix: @prefix,
        name: :wifi_map_views_unique_name_idx
      )
    )

    execute("""
    CREATE UNIQUE INDEX wifi_map_views_single_default_dashboard_idx
    ON #{@prefix}.wifi_map_views (is_default_dashboard)
    WHERE is_default_dashboard = true;
    """)
  end

  def down do
    execute("DROP INDEX IF EXISTS #{@prefix}.wifi_map_views_single_default_dashboard_idx;")
    drop(table(:wifi_map_views, prefix: @prefix))
    drop(table(:wifi_fleet_history, prefix: @prefix))
    drop(table(:wifi_radius_group_observations, prefix: @prefix))
    drop(table(:wifi_controller_observations, prefix: @prefix))
    drop(table(:wifi_access_point_observations, prefix: @prefix))
    drop(table(:wifi_site_snapshots, prefix: @prefix))
    drop(table(:wifi_sites, prefix: @prefix))
    drop(table(:wifi_site_references, prefix: @prefix))
    drop(table(:wifi_map_batches, prefix: @prefix))
    drop(table(:wifi_map_sources, prefix: @prefix))
  end

  defp add_location_column(table_name) do
    execute("""
    ALTER TABLE #{@prefix}.#{table_name}
    ADD COLUMN location geography(Point, 4326)
    GENERATED ALWAYS AS (
      CASE
        WHEN latitude IS NOT NULL AND longitude IS NOT NULL
        THEN ST_SetSRID(ST_MakePoint(longitude, latitude), 4326)::geography
        ELSE NULL
      END
    ) STORED;
    """)
  end

  defp add_coordinate_constraints(table_name) do
    create(
      constraint(table_name, :"#{table_name}_latitude_range",
        prefix: @prefix,
        check: "latitude IS NULL OR (latitude >= -90 AND latitude <= 90)"
      )
    )

    create(
      constraint(table_name, :"#{table_name}_longitude_range",
        prefix: @prefix,
        check: "longitude IS NULL OR (longitude >= -180 AND longitude <= 180)"
      )
    )
  end

  defp create_gist_index(table_name, column_name) do
    execute("""
    CREATE INDEX #{table_name}_#{column_name}_gist_idx
    ON #{@prefix}.#{table_name}
    USING gist (#{column_name})
    WHERE #{column_name} IS NOT NULL;
    """)
  end
end
