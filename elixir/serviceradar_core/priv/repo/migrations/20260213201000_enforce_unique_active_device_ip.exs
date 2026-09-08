defmodule ServiceRadar.Repo.Migrations.EnforceUniqueActiveDeviceIp do
  @moduledoc """
  Ensures only one active device row exists per IP address.

  This migration is idempotent:
  1. Compacts existing duplicate active-IP device rows by re-pointing references
     to a canonical row and soft-deleting duplicates.
  2. Adds a partial unique index on active, non-empty IP values.
  """

  use Ecto.Migration

  def up do
    execute("""
    DO $$
    DECLARE
      rec RECORD;
    BEGIN
      FOR rec IN
        WITH ranked AS (
          SELECT
            uid,
            ip,
            ROW_NUMBER() OVER (
              PARTITION BY ip
              ORDER BY COALESCE(last_seen_time, modified_time, created_time) DESC NULLS LAST, uid ASC
            ) AS rn
          FROM platform.ocsf_devices
          WHERE deleted_at IS NULL
            AND ip IS NOT NULL
            AND ip <> ''
        )
        SELECT d.uid AS duplicate_uid, c.uid AS canonical_uid
        FROM ranked d
        JOIN ranked c ON c.ip = d.ip AND c.rn = 1
        WHERE d.rn > 1
      LOOP
        -- Preserve useful canonical attributes before retiring the duplicate.
        UPDATE platform.ocsf_devices c
        SET
          hostname = COALESCE(c.hostname, d.hostname),
          mac = COALESCE(c.mac, d.mac),
          vendor_name = COALESCE(c.vendor_name, d.vendor_name),
          model = COALESCE(c.model, d.model),
          metadata = COALESCE(c.metadata, '{}'::jsonb) || COALESCE(d.metadata, '{}'::jsonb),
          discovery_sources = (
            SELECT ARRAY(
              SELECT DISTINCT x
              FROM unnest(COALESCE(c.discovery_sources, ARRAY[]::text[]) || COALESCE(d.discovery_sources, ARRAY[]::text[])) AS x
              WHERE x IS NOT NULL AND x <> ''
            )
          ),
          modified_time = NOW() AT TIME ZONE 'utc',
          last_seen_time = GREATEST(c.last_seen_time, d.last_seen_time)
        FROM platform.ocsf_devices d
        WHERE c.uid = rec.canonical_uid
          AND d.uid = rec.duplicate_uid;

        DELETE FROM platform.discovered_interfaces d
        USING platform.discovered_interfaces c
        WHERE d.device_id = rec.duplicate_uid
          AND c.device_id = rec.canonical_uid
          AND d.timestamp = c.timestamp
          AND d.interface_uid = c.interface_uid;

        UPDATE platform.discovered_interfaces
        SET device_id = rec.canonical_uid
        WHERE device_id = rec.duplicate_uid;

        UPDATE platform.alerts
        SET device_uid = rec.canonical_uid
        WHERE device_uid = rec.duplicate_uid;

        UPDATE platform.service_checks
        SET device_uid = rec.canonical_uid
        WHERE device_uid = rec.duplicate_uid;

        UPDATE platform.ocsf_agents
        SET device_uid = rec.canonical_uid
        WHERE device_uid = rec.duplicate_uid;

        UPDATE platform.device_snmp_credentials
        SET device_id = rec.canonical_uid
        WHERE device_id = rec.duplicate_uid;

        UPDATE platform.device_updates
        SET device_id = rec.canonical_uid
        WHERE device_id = rec.duplicate_uid;

        INSERT INTO platform.device_identifiers (
          device_id,
          identifier_type,
          identifier_value,
          partition,
          confidence,
          source,
          first_seen,
          last_seen,
          verified,
          metadata
        )
        SELECT
          rec.canonical_uid,
          di.identifier_type,
          di.identifier_value,
          di.partition,
          di.confidence,
          COALESCE(di.source, 'duplicate_ip_compaction'),
          di.first_seen,
          di.last_seen,
          di.verified,
          COALESCE(di.metadata, '{}'::jsonb)
        FROM platform.device_identifiers di
        WHERE di.device_id = rec.duplicate_uid
        ON CONFLICT (identifier_type, identifier_value, partition) DO UPDATE
        SET
          device_id = EXCLUDED.device_id,
          last_seen = GREATEST(platform.device_identifiers.last_seen, EXCLUDED.last_seen),
          metadata = COALESCE(platform.device_identifiers.metadata, '{}'::jsonb) ||
                     jsonb_build_object('compacted_duplicate_ip', true);

        DELETE FROM platform.device_identifiers
        WHERE device_id = rec.duplicate_uid;

        INSERT INTO platform.device_alias_states (
          device_id,
          partition,
          alias_type,
          alias_value,
          state,
          first_seen_at,
          last_seen_at,
          sighting_count,
          metadata,
          previous_alias_id,
          replaced_by_alias_id,
          inserted_at,
          updated_at
        )
        SELECT
          rec.canonical_uid,
          das.partition,
          das.alias_type,
          das.alias_value,
          das.state,
          das.first_seen_at,
          das.last_seen_at,
          das.sighting_count,
          COALESCE(das.metadata, '{}'::jsonb),
          das.previous_alias_id,
          das.replaced_by_alias_id,
          das.inserted_at,
          das.updated_at
        FROM platform.device_alias_states das
        WHERE das.device_id = rec.duplicate_uid
        ON CONFLICT (device_id, alias_type, alias_value) DO NOTHING;

        DELETE FROM platform.device_alias_states
        WHERE device_id = rec.duplicate_uid;

        UPDATE platform.ocsf_devices
        SET
          deleted_at = COALESCE(deleted_at, NOW() AT TIME ZONE 'utc'),
          deleted_by = COALESCE(deleted_by, 'migration:duplicate_ip_compaction'),
          deleted_reason = COALESCE(deleted_reason, 'duplicate_active_ip'),
          modified_time = NOW() AT TIME ZONE 'utc'
        WHERE uid = rec.duplicate_uid;
      END LOOP;
    END
    $$;
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS ocsf_devices_unique_active_ip_idx
      ON platform.ocsf_devices (ip)
      WHERE deleted_at IS NULL AND ip IS NOT NULL AND ip <> '';
    """)
  end

  def down do
    execute("""
    DROP INDEX IF EXISTS platform.ocsf_devices_unique_active_ip_idx;
    """)
  end
end
