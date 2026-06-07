defmodule ServiceRadar.Repo.Migrations.AddEndpointInventoryCanonicalPurlIndexes do
  @moduledoc false
  use Ecto.Migration

  def up do
    # serviceradar:allow-startup-maintenance - schema-critical bounded
    # normalization required before enforcing purl_canonical NOT NULL.
    alter table(:endpoint_inventory_packages, prefix: "platform") do
      add(:purl_canonical, :text)
    end

    execute("""
    UPDATE platform.endpoint_inventory_packages
    SET purl_canonical = COALESCE(
      NULLIF(purl, ''),
      'pkg:' || lower(package_manager) || '/' || name ||
        COALESCE('@' || NULLIF(version, ''), '') ||
        CASE
          WHEN architecture IS NULL OR architecture = '' THEN ''
          ELSE '?arch=' || architecture
        END
    )
    WHERE purl_canonical IS NULL
    """)

    alter table(:endpoint_inventory_packages, prefix: "platform") do
      modify(:purl_canonical, :text, null: false)
    end

    create(
      index(:endpoint_inventory_packages, [:purl_canonical],
        name: "endpoint_inventory_packages_purl_canonical_idx",
        prefix: "platform"
      )
    )

    execute("""
    CREATE INDEX IF NOT EXISTS endpoint_inventory_packages_cpes_gin_idx
    ON platform.endpoint_inventory_packages
    USING GIN (cpes)
    """)
  end

  def down do
    execute("DROP INDEX IF EXISTS platform.endpoint_inventory_packages_cpes_gin_idx")

    drop_if_exists(
      index(:endpoint_inventory_packages, [:purl_canonical],
        name: "endpoint_inventory_packages_purl_canonical_idx",
        prefix: "platform"
      )
    )

    alter table(:endpoint_inventory_packages, prefix: "platform") do
      remove(:purl_canonical)
    end
  end
end
