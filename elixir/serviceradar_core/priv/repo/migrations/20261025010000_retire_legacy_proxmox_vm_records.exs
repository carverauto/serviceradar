defmodule ServiceRadar.Repo.Migrations.RetireLegacyProxmoxVmRecords do
  @moduledoc """
  Retires legacy unscoped Proxmox `integration_id` records (`proxmox:vm:*`,
  `proxmox:container:*`, `proxmox:hypervisor:*`) through source retirement
  (`device_identifier_archive` with `archive_reason = 'source_absent'`,
  `identity_decisions` with `decision_kind = 'source_id_retired'`, and
  `ocsf_devices.source_retired_at`) and backfills `ocsf_devices.ip` on live
  addressless AWX records whose metadata carries an unheld `ansible_host` IPv4
  address.
  """
  use Ecto.Migration

  def up do
    schema = prefix() || "platform"

    execute("""
    WITH moved AS (
      DELETE FROM #{schema}.device_identifiers AS di
      WHERE di.identifier_type::text = 'integration_id'
        AND btrim(di.identifier_value) ~* '^proxmox:(vm|container|hypervisor):'
      RETURNING di.*
    )
    INSERT INTO #{schema}.device_identifier_archive
      (id, device_id, identifier_type, identifier_value, partition, confidence,
       source, first_seen, last_seen, verified, metadata, archived_at, archive_reason)
    SELECT id, device_id, identifier_type::text, identifier_value,
           COALESCE(partition, 'default'), confidence::text, source,
           first_seen AT TIME ZONE 'UTC', last_seen AT TIME ZONE 'UTC',
           COALESCE(verified, false), COALESCE(metadata, '{}'::jsonb),
           timezone('utc', now()), 'source_absent'
    FROM moved
    ON CONFLICT (id) DO UPDATE SET
      archive_reason = 'source_absent',
      archived_at = EXCLUDED.archived_at
    """)

    execute("""
    UPDATE #{schema}.ocsf_devices AS d
    SET source_retired_at = timezone('utc', now())
    WHERE d.deleted_at IS NULL
      AND d.source_retired_at IS NULL
      AND NULLIF(btrim(COALESCE(d.agent_id, '')), '') IS NULL
      AND NOT (COALESCE(d.discovery_sources, ARRAY[]::text[]) && ARRAY['manual']::text[])
      AND EXISTS (
        SELECT 1
        FROM #{schema}.device_identifier_archive AS a
        WHERE a.device_id = d.uid
          AND a.identifier_type = 'integration_id'
          AND btrim(a.identifier_value) ~* '^proxmox:(vm|container|hypervisor):'
      )
      AND NOT EXISTS (
        SELECT 1
        FROM #{schema}.device_identifiers AS di
        WHERE di.device_id = d.uid
      )
      AND NOT #{schema}.device_held_for_review(d.uid)
    """)

    execute("""
    INSERT INTO #{schema}.identity_decisions
      (id, decision_kind, reason, device_uids, subject, decision_key, source,
       evidence, occurrence_count, first_decided_at, last_decided_at, inserted_at, updated_at)
    SELECT
      gen_random_uuid(),
      'source_id_retired',
      'source_absent',
      ARRAY[a.device_id]::text[],
      a.identifier_value,
      encode(
        sha256(
          convert_to(
            'source_id_retired' || E'\\n' || 'source_absent' || E'\\n' ||
            a.identifier_value || E'\\n' || a.device_id,
            'UTF8'
          )
        ),
        'hex'
      ),
      'source_retirement',
      jsonb_build_object(
        'identifier_type', 'integration_id',
        'identifier_value', a.identifier_value,
        'identifier_partition', COALESCE(a.partition, 'default'),
        'archived_identifier_id', a.id,
        'source', 'proxmox',
        'marked_source_retired', (d.source_retired_at IS NOT NULL)
      ),
      1,
      timezone('utc', now()),
      timezone('utc', now()),
      timezone('utc', now()),
      timezone('utc', now())
    FROM #{schema}.device_identifier_archive AS a
    JOIN #{schema}.ocsf_devices AS d ON d.uid = a.device_id
    WHERE a.identifier_type = 'integration_id'
      AND btrim(a.identifier_value) ~* '^proxmox:(vm|container|hypervisor):'
    ON CONFLICT (decision_key) DO NOTHING
    """)

    execute("""
    WITH awx_candidates AS (
      SELECT DISTINCT ON (COALESCE(d.partition, 'default'), candidate_ip)
        d.uid,
        COALESCE(d.partition, 'default') AS partition,
        candidate_ip
      FROM #{schema}.ocsf_devices AS d
      CROSS JOIN LATERAL (
        SELECT btrim(
          COALESCE(
            NULLIF(btrim(d.metadata->'awx'->>'ansible_host'), ''),
            NULLIF(btrim(d.metadata->'awx'->>'ansible_ssh_host'), ''),
            NULLIF(btrim(d.metadata->>'ansible_host'), ''),
            NULLIF(btrim(d.metadata->>'ansible_ssh_host'), '')
          )
        ) AS candidate_ip
      ) AS extracted
      WHERE d.deleted_at IS NULL
        AND NULLIF(btrim(COALESCE(d.ip, '')), '') IS NULL
        AND candidate_ip ~ '^(?:(?:25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])\\.){3}(?:25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])$'
      ORDER BY COALESCE(d.partition, 'default'), candidate_ip, d.uid
    )
    UPDATE #{schema}.ocsf_devices AS d
    SET ip = c.candidate_ip,
        modified_time = timezone('utc', now())
    FROM awx_candidates AS c
    WHERE d.uid = c.uid
      AND NOT EXISTS (
        SELECT 1
        FROM #{schema}.ocsf_devices AS holder
        WHERE holder.deleted_at IS NULL
          AND holder.uid <> d.uid
          AND COALESCE(holder.partition, 'default') = c.partition
          AND holder.ip = c.candidate_ip
      )
    """)
  end

  def down do
    :ok
  end
end
