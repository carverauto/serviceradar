defmodule ServiceRadar.Repo.Migrations.MigrateRoleProfilePermissionKeys do
  @moduledoc """
  One-time migration to replace deprecated/typo RBAC permission keys stored in
  `platform.role_profiles.permissions`.

  We intentionally do this in SQL so the app does not carry backward-compat
  alias logic forever.
  """

  use Ecto.Migration

  @observability_view_expansion [
    "observability.logs.view",
    "observability.metrics.view",
    "observability.traces.view",
    "observability.events.view",
    "observability.netflow.view",
    "observability.alerts.view",
    "observability.rules.view"
  ]

  def up do
    execute("CREATE SCHEMA IF NOT EXISTS platform")

    expanded = Enum.map_join(@observability_view_expansion, ",", &"'#{&1}'")

    execute("""
    UPDATE platform.role_profiles rp
    SET permissions = (
      SELECT COALESCE(array_agg(DISTINCT perm ORDER BY perm), ARRAY[]::text[])
      FROM (
        -- Keep existing keys (and fix known typos), but drop deprecated alias keys.
        SELECT CASE
          WHEN p = 'devices.crate' THEN 'devices.create'
          ELSE p
        END AS perm
        FROM unnest(COALESCE(rp.permissions, ARRAY[]::text[])) AS p
        WHERE p <> 'observability.view'

        UNION ALL

        -- Expand deprecated observability.view into the new granular keys if present.
        SELECT unnest(ARRAY[#{expanded}]) AS perm
        WHERE 'observability.view' = ANY(COALESCE(rp.permissions, ARRAY[]::text[]))
      ) s
    )
    """)
  end

  def down do
    # No-op: we don't want to re-introduce deprecated keys.
    :ok
  end
end

