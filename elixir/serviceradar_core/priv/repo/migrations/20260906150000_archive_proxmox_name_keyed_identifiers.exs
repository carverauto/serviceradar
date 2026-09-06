defmodule ServiceRadar.Repo.Migrations.ArchiveProxmoxNameKeyedIdentifiers do
  @moduledoc """
  Archive Proxmox gen-1 name-keyed integration identifiers and scrub matching
  metadata bridges.

  Writer-side `IntegrationIdentity.legacy_candidates/2` no longer emits bare
  guest/hostname bridges and `Ids.get_identifier_values/2` never honors them
  as lookups, but the identifier *rows* minted by earlier generations remain:
  GitHub #4051 measured 68 legacy `proxmox:vm:<name>` /
  `proxmox:container:<name>` / `proxmox:hypervisor:<node>` rows across 66
  devices, 14 of which fused devices from different clusters into one row.
  Every cross-cluster fusion traced to a name-keyed identifier.

  Archives, does not delete: stale identity rows in this system have a history
  of self-reviving, so the rows move to
  `platform.device_identifier_archive` with their full provenance instead of
  vanishing. Post-fix producers cannot re-register these shapes (nothing mints
  gen-1 primaries anymore and ambiguous values never match), so the archive
  cannot refill from the same cause.

  This migration archives only the gen-1 bare-name families selected by
  `ambiguous_predicate/1`. Other unscoped forms remain in storage; storage
  retention does not make them admissible under `IntegrationIdentity`.

  The same predicate removes matching tokens from
  `ocsf_devices.metadata.legacy_integration_ids` arrays. It is deliberately
  narrower than the current runtime admissibility guard.
  """
  use Ecto.Migration

  def up do
    schema = prefix() || "platform"

    execute("""
    CREATE TABLE IF NOT EXISTS #{schema}.device_identifier_archive (
      id bigint PRIMARY KEY,
      device_id text NOT NULL,
      identifier_type text NOT NULL,
      identifier_value text NOT NULL,
      partition text NOT NULL DEFAULT 'default',
      confidence text,
      source text,
      first_seen timestamptz,
      last_seen timestamptz,
      verified boolean NOT NULL DEFAULT false,
      metadata jsonb NOT NULL DEFAULT '{}',
      archived_at timestamptz NOT NULL DEFAULT timezone('utc', now()),
      archive_reason text NOT NULL DEFAULT ''
    )
    """)

    execute("""
    INSERT INTO #{schema}.device_identifier_archive
      (id, device_id, identifier_type, identifier_value, partition, confidence,
       source, first_seen, last_seen, verified, metadata, archive_reason)
    SELECT id, device_id, identifier_type::text, identifier_value, partition,
           confidence::text, source, first_seen, last_seen, verified, metadata,
           'proxmox_name_keyed_github_4051'
    FROM #{schema}.device_identifiers
    WHERE identifier_type::text = 'integration_id'
      AND #{ambiguous_predicate("identifier_value")}
    ON CONFLICT (id) DO NOTHING
    """)

    execute("""
    DELETE FROM #{schema}.device_identifiers
    WHERE identifier_type::text = 'integration_id'
      AND #{ambiguous_predicate("identifier_value")}
    """)

    execute("""
    WITH flagged AS (
      SELECT d.uid,
        (SELECT jsonb_agg(elem) FROM (
          SELECT elem
          FROM jsonb_array_elements_text(d.metadata->'legacy_integration_ids') AS elem
          WHERE NOT (#{ambiguous_predicate("elem")})
        ) s) AS kept
      FROM #{schema}.ocsf_devices d
      WHERE jsonb_typeof(d.metadata->'legacy_integration_ids') = 'array'
        AND EXISTS (
          SELECT 1
          FROM jsonb_array_elements_text(d.metadata->'legacy_integration_ids') AS e
          WHERE #{ambiguous_predicate("e")}
        )
    )
    UPDATE #{schema}.ocsf_devices d
    SET metadata = CASE WHEN flagged.kept IS NULL
                        THEN d.metadata - 'legacy_integration_ids'
                        ELSE jsonb_set(d.metadata, '{legacy_integration_ids}', flagged.kept)
                   END,
        modified_time = timezone('utc', now())
    FROM flagged
    WHERE d.uid = flagged.uid
    """)
  end

  def down do
    raise "cannot restore archived Proxmox name-keyed identifiers"
  end

  # Preserve the migration's bounded archive population: bare guest names
  # and hypervisor names, excluding numeric guest refs and slash/MAC forms.
  # Runtime admissibility is owned by IntegrationIdentity and is stricter.
  @doc false
  def ambiguous_predicate(column) do
    """
    ((btrim(#{column}) ~ '^proxmox:(vm|container):[^:/]+$' AND split_part(btrim(#{column}), ':', 3) !~ '^[0-9]+$') OR btrim(#{column}) ~ '^proxmox:hypervisor:.+$')
    """
  end
end
