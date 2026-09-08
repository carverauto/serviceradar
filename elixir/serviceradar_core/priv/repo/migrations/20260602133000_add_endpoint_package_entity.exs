defmodule ServiceRadar.Repo.Migrations.AddEndpointPackageEntity do
  @moduledoc false
  use Ecto.Migration

  def up do
    # serviceradar:allow-startup-maintenance - schema-critical bounded
    # package entity backfill required before endpoint_package_ref is NOT NULL.
    create table(:endpoint_packages, primary_key: false, prefix: "platform") do
      add(:id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:coordinate_key, :text, null: false)
      add(:purl_canonical, :text)
      add(:primary_cpe, :text)
      add(:cpes, {:array, :text}, null: false, default: [])
      add(:package_manager, :text, null: false)
      add(:name, :text, null: false)
      add(:version, :text)
      add(:architecture, :text)
      add(:ecosystem, :text)
      add(:source_scope, :text, null: false, default: "host")
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
      unique_index(:endpoint_packages, [:coordinate_key],
        name: "endpoint_packages_coordinate_key_uidx",
        prefix: "platform"
      )
    )

    create(
      index(:endpoint_packages, [:purl_canonical],
        name: "endpoint_packages_purl_canonical_idx",
        prefix: "platform",
        where: "purl_canonical IS NOT NULL"
      )
    )

    execute("""
    CREATE INDEX IF NOT EXISTS endpoint_packages_cpes_gin_idx
      ON platform.endpoint_packages
      USING GIN (cpes)
    """)

    create(
      index(:endpoint_packages, [:package_manager, :name, :version],
        name: "endpoint_packages_manager_name_version_idx",
        prefix: "platform"
      )
    )

    alter table(:endpoint_inventory_packages, prefix: "platform") do
      add(
        :endpoint_package_ref,
        references(:endpoint_packages,
          type: :uuid,
          on_delete: :restrict,
          prefix: "platform"
        )
      )
    end

    backfill_endpoint_packages()

    alter table(:endpoint_inventory_packages, prefix: "platform") do
      modify(:endpoint_package_ref, :uuid, null: false)
    end

    create(
      index(:endpoint_inventory_packages, [:endpoint_package_ref],
        name: "endpoint_inventory_packages_package_ref_idx",
        prefix: "platform"
      )
    )

    create(
      index(:endpoint_inventory_packages, [:device_uid, :current, :endpoint_package_ref],
        name: "endpoint_inventory_packages_device_current_package_idx",
        prefix: "platform",
        where: "device_uid IS NOT NULL"
      )
    )
  end

  def down do
    drop_if_exists(
      index(:endpoint_inventory_packages, [:device_uid, :current, :endpoint_package_ref],
        name: "endpoint_inventory_packages_device_current_package_idx",
        prefix: "platform"
      )
    )

    drop_if_exists(
      index(:endpoint_inventory_packages, [:endpoint_package_ref],
        name: "endpoint_inventory_packages_package_ref_idx",
        prefix: "platform"
      )
    )

    alter table(:endpoint_inventory_packages, prefix: "platform") do
      remove(:endpoint_package_ref)
    end

    execute("DROP INDEX IF EXISTS platform.endpoint_packages_cpes_gin_idx")
    drop_if_exists(table(:endpoint_packages, prefix: "platform"))
  end

  defp backfill_endpoint_packages do
    execute("""
    INSERT INTO platform.endpoint_packages (
      coordinate_key,
      purl_canonical,
      primary_cpe,
      cpes,
      package_manager,
      name,
      version,
      architecture,
      ecosystem,
      source_scope,
      metadata,
      inserted_at,
      updated_at
    )
    SELECT DISTINCT ON ('purl:' || purl_canonical)
      'purl:' || purl_canonical AS coordinate_key,
      purl_canonical,
      NULLIF((SELECT cpe FROM unnest(cpes) AS cpe ORDER BY cpe LIMIT 1), '') AS primary_cpe,
      cpes,
      package_manager,
      name,
      version,
      architecture,
      ecosystem,
      'host',
      jsonb_build_object('source', 'endpoint_inventory_backfill'),
      (now() AT TIME ZONE 'utc'),
      (now() AT TIME ZONE 'utc')
    FROM platform.endpoint_inventory_packages
    WHERE purl_canonical IS NOT NULL
    ORDER BY 'purl:' || purl_canonical, current DESC, inserted_at DESC
    ON CONFLICT (coordinate_key) DO UPDATE SET
      purl_canonical = EXCLUDED.purl_canonical,
      primary_cpe = EXCLUDED.primary_cpe,
      cpes = EXCLUDED.cpes,
      package_manager = EXCLUDED.package_manager,
      name = EXCLUDED.name,
      version = EXCLUDED.version,
      architecture = EXCLUDED.architecture,
      ecosystem = EXCLUDED.ecosystem,
      updated_at = EXCLUDED.updated_at
    """)

    execute("""
    UPDATE platform.endpoint_inventory_packages AS inventory_package
    SET endpoint_package_ref = endpoint_package.id
    FROM platform.endpoint_packages AS endpoint_package
    WHERE endpoint_package.coordinate_key = 'purl:' || inventory_package.purl_canonical
      AND inventory_package.endpoint_package_ref IS NULL
    """)
  end
end
