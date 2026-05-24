defmodule ServiceRadar.Repo.Migrations.EnforceSingleApprovedPluginPackage do
  @moduledoc false
  use Ecto.Migration

  def up do
    # serviceradar:allow-startup-maintenance - schema-critical bounded cleanup before adding
    # the partial unique index; only duplicate approved plugin package rows are touched.
    execute("""
    WITH ranked AS (
      SELECT
        id,
        row_number() OVER (
          PARTITION BY plugin_id
          ORDER BY
            CASE
              WHEN version ~ '^v?[0-9]+\\.[0-9]+\\.[0-9]+'
              THEN split_part(regexp_replace(version, '^v', ''), '.', 1)::integer
              ELSE -1
            END DESC,
            CASE
              WHEN version ~ '^v?[0-9]+\\.[0-9]+\\.[0-9]+'
              THEN split_part(regexp_replace(version, '^v', ''), '.', 2)::integer
              ELSE -1
            END DESC,
            CASE
              WHEN version ~ '^v?[0-9]+\\.[0-9]+\\.[0-9]+'
              THEN split_part(regexp_replace(version, '^v', ''), '.', 3)::integer
              ELSE -1
            END DESC,
            imported_at DESC NULLS LAST,
            approved_at DESC NULLS LAST,
            inserted_at DESC
        ) AS rank
      FROM platform.plugin_packages
      WHERE status = 'approved'
    )
    UPDATE platform.plugin_packages AS package
    SET status = 'revoked',
        denied_reason = 'superseded by newer approved package',
        updated_at = now()
    FROM ranked
    WHERE package.id = ranked.id
      AND ranked.rank > 1
    """)

    execute("""
    UPDATE platform.plugin_assignments AS assignment
    SET enabled = false,
        updated_at = now()
    FROM platform.plugin_packages AS package
    WHERE assignment.plugin_package_id = package.id
      AND package.status <> 'approved'
      AND assignment.enabled = true
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS plugin_packages_one_approved_per_plugin_index
    ON platform.plugin_packages (plugin_id)
    WHERE status = 'approved'
    """)
  end

  def down do
    execute("DROP INDEX IF EXISTS platform.plugin_packages_one_approved_per_plugin_index")
  end
end
