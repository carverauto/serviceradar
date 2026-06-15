defmodule ServiceRadar.Repo.Migrations.AddAdvisoryCoordinates do
  @moduledoc """
  Adds the disk-staged / core-ingested advisory storage redesign:

    * `raw jsonb` + GIN(jsonb_path_ops) on `vulnerability_advisories`, holding the
      complete upstream CVE object for provenance and ad-hoc extraction.
    * `generation` + `current` columns so a feed run can stage a new generation
      and atomically swap it in (matching always reads one consistent generation).
    * a normalized `platform.advisory_coordinates` table, one row per CPE / PURL /
      vendor_product coordinate, with parsed CPE-2.3 components and discrete
      version-bound columns so endpoint CPE matching is set-based and indexed
      instead of parsing JSONB at query time.

  `pg_trgm` is already bootstrapped (see 20260117080000_bootstrap_extensions.exs),
  so the trigram index on `value` can be created directly.
  """
  use Ecto.Migration

  def up do
    alter table(:vulnerability_advisories, prefix: "platform") do
      add(:raw, :map, null: false, default: %{})
      add(:generation, :bigint, null: false, default: 0)
      add(:current, :boolean, null: false, default: true)
    end

    execute("""
    CREATE INDEX IF NOT EXISTS vulnerability_advisories_raw_gin_idx
      ON platform.vulnerability_advisories
      USING GIN (raw jsonb_path_ops)
    """)

    create(
      index(:vulnerability_advisories, [:provider, :feed_key, :generation, :current],
        name: "vulnerability_advisories_generation_idx",
        prefix: "platform"
      )
    )

    create table(:advisory_coordinates, primary_key: false, prefix: "platform") do
      add(:id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)

      add(
        :advisory_ref,
        references(:vulnerability_advisories,
          type: :uuid,
          on_delete: :delete_all,
          prefix: "platform"
        ),
        null: false
      )

      add(:provider, :text, null: false)
      add(:feed_key, :text, null: false)
      add(:generation, :bigint, null: false, default: 0)
      # coordinate_type: cpe | purl | vendor_product
      add(:coordinate_type, :text, null: false)
      add(:value, :text, null: false)

      # Parsed CPE-2.3 components (lower-cased; "*"/"-" preserved as-is).
      add(:cpe_part, :text)
      add(:cpe_vendor, :text)
      add(:cpe_product, :text)
      add(:cpe_version, :text)

      # Normalized NVD version-range bounds.
      add(:version_start, :text)
      add(:version_start_inclusive, :boolean)
      add(:version_end, :text)
      add(:version_end_inclusive, :boolean)

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

    # Identity for bulk upserts: one coordinate row per advisory + type + value +
    # version bounds. Version bounds are part of the identity because NVD emits
    # several cpeMatch entries for the same CPE with different version windows.
    create(
      unique_index(
        :advisory_coordinates,
        [
          :advisory_ref,
          :coordinate_type,
          :value,
          :version_start,
          :version_end
        ],
        name: "advisory_coordinates_identity_uidx",
        prefix: "platform",
        nulls_distinct: false
      )
    )

    # Component join: vendor/product btree for the package -> advisory match.
    create(
      index(:advisory_coordinates, [:cpe_vendor, :cpe_product],
        name: "advisory_coordinates_vendor_product_idx",
        prefix: "platform",
        where: "cpe_vendor IS NOT NULL"
      )
    )

    # PURL exact + coordinate_type filtering.
    create(
      index(:advisory_coordinates, [:coordinate_type, :value],
        name: "advisory_coordinates_type_value_idx",
        prefix: "platform"
      )
    )

    # Generation scoping for consistent reads + reaper.
    create(
      index(:advisory_coordinates, [:provider, :feed_key, :generation],
        name: "advisory_coordinates_generation_idx",
        prefix: "platform"
      )
    )

    # Trigram on the literal value for wildcard / partial CPE string matching.
    execute("""
    CREATE INDEX IF NOT EXISTS advisory_coordinates_value_trgm_idx
      ON platform.advisory_coordinates
      USING GIN (value gin_trgm_ops)
    """)
  end

  def down do
    execute("DROP INDEX IF EXISTS platform.advisory_coordinates_value_trgm_idx")
    drop_if_exists(table(:advisory_coordinates, prefix: "platform"))

    drop_if_exists(
      index(:vulnerability_advisories, [:provider, :feed_key, :generation, :current],
        name: "vulnerability_advisories_generation_idx",
        prefix: "platform"
      )
    )

    execute("DROP INDEX IF EXISTS platform.vulnerability_advisories_raw_gin_idx")

    alter table(:vulnerability_advisories, prefix: "platform") do
      remove(:raw)
      remove(:generation)
      remove(:current)
    end
  end
end
