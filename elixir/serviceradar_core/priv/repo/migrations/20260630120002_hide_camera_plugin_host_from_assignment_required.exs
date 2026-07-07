defmodule ServiceRadar.Repo.Migrations.HideCameraPluginHostFromAssignmentRequired do
  @moduledoc """
  Backfill already-imported plugin_packages whose config_schema still declares the
  per-target runtime field `host` as a top-level `required` property.

  Camera plugins (axis, unifi-protect) historically shipped a config schema with
  `"required": ["host"]`, but `host` is injected per TARGET at runtime from
  credential rules / SRQL-scoped targets, not configured per assignment. That made
  assignment validation fail with "Required property host was not present".

  The Go bundle schemas are corrected at source, but the assignment validator reads
  `config_schema` off the platform.plugin_packages DB row (written at import time),
  so already-imported packages stay broken until refreshed. This migration mirrors
  the source fix in place:

    * removes "host" from config_schema['required'] (dropping the key when it
      becomes empty, matching the corrected source schema), and
    * sets config_schema['properties']['host']['x-serviceradar-ui-hidden'] = true
      so the validator's runtime_injected_property?/1 strips it from required.

  Scoped to only rows whose required array currently contains "host" and that have
  a properties.host object, so it is idempotent: re-running is a no-op because the
  WHERE no longer matches.
  """
  use Ecto.Migration

  def up do
    # serviceradar:allow-startup-maintenance - bounded, schema-critical one-time backfill.
    # platform.plugin_packages is a small control-plane table (one row per installed plugin
    # package, not a hypertable), so this single UPDATE touches only the handful of imported
    # camera-plugin rows in the first-boot Job with no large-table lock/timeout risk. It is
    # required for correctness (assignment validation reads config_schema off this DB row, so
    # already-imported packages stay broken until rewritten) and idempotent: the WHERE clause
    # no longer matches once `host` has been removed from `required`, so a re-run is a no-op.
    execute("""
    UPDATE platform.plugin_packages
    SET config_schema = jsonb_set(
          CASE
            WHEN COALESCE(
                   (
                     SELECT jsonb_agg(elem)
                     FROM jsonb_array_elements(config_schema::jsonb -> 'required') AS elem
                     WHERE elem <> '"host"'::jsonb
                   ),
                   '[]'::jsonb
                 ) = '[]'::jsonb
              THEN (config_schema::jsonb) #- '{required}'
            ELSE jsonb_set(
                   config_schema::jsonb,
                   '{required}',
                   COALESCE(
                     (
                       SELECT jsonb_agg(elem)
                       FROM jsonb_array_elements(config_schema::jsonb -> 'required') AS elem
                       WHERE elem <> '"host"'::jsonb
                     ),
                     '[]'::jsonb
                   ),
                   false
                 )
          END,
          '{properties,host,x-serviceradar-ui-hidden}',
          'true'::jsonb,
          true
        ),
        updated_at = now()
    WHERE config_schema::jsonb -> 'required' @> '["host"]'::jsonb
      AND config_schema::jsonb #> '{properties,host}' IS NOT NULL
    """)
  end

  def down do
    # Best-effort reverse: re-add "host" to required and drop the hidden flag for
    # rows we previously rewrote (host hidden + not currently required).
    execute("""
    UPDATE platform.plugin_packages
    SET config_schema = jsonb_set(
          (config_schema::jsonb) #- '{properties,host,x-serviceradar-ui-hidden}',
          '{required}',
          COALESCE(config_schema::jsonb -> 'required', '[]'::jsonb) || '["host"]'::jsonb,
          true
        ),
        updated_at = now()
    WHERE (config_schema::jsonb #> '{properties,host,x-serviceradar-ui-hidden}') = 'true'::jsonb
      AND NOT (COALESCE(config_schema::jsonb -> 'required', '[]'::jsonb) @> '["host"]'::jsonb)
    """)
  end
end
