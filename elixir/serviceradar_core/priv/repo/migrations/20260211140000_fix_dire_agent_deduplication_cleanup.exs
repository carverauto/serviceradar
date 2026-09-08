defmodule ServiceRadar.Repo.Migrations.FixDireAgentDeduplicationCleanup do
  @moduledoc """
  Consolidates duplicate agent devices and backfills agent_id identifiers.

  Problem: DIRE's agent_id identifier was never registered in device_identifiers,
  causing k8s agents with ephemeral IPs to create a new device on every pod restart.

  This migration:
  1. For each agent_id with multiple devices, keeps the one the agent record currently
     references (or the most recent), reassigns associated records, deletes duplicates.
  2. Backfills device_identifiers for all devices that have agent_id set on ocsf_devices
     but no corresponding :agent_id row in device_identifiers.
  """

  use Ecto.Migration

  def up do
    # Step 1: Consolidate duplicate agent devices
    # For each agent_id with >1 device, keep the canonical one and merge the rest.
    execute("""
    DO $$
    DECLARE
      rec RECORD;
      canonical_uid TEXT;
      dup RECORD;
    BEGIN
      -- Find agent_ids with duplicate devices
      FOR rec IN
        SELECT agent_id
        FROM platform.ocsf_devices
        WHERE agent_id IS NOT NULL AND agent_id != ''
        GROUP BY agent_id
        HAVING COUNT(*) > 1
      LOOP
        -- Pick canonical device: the one referenced by ocsf_agents, or most recently created
        SELECT COALESCE(
          (SELECT device_uid FROM platform.ocsf_agents WHERE uid = rec.agent_id),
          (SELECT uid FROM platform.ocsf_devices WHERE agent_id = rec.agent_id ORDER BY created_time DESC LIMIT 1)
        ) INTO canonical_uid;

        -- Reassign associated records from duplicates to canonical
        UPDATE platform.discovered_interfaces
        SET device_id = canonical_uid
        WHERE device_id IN (
          SELECT uid FROM platform.ocsf_devices
          WHERE agent_id = rec.agent_id AND uid != canonical_uid
        );

        UPDATE platform.sweep_host_results
        SET device_id = canonical_uid
        WHERE device_id IN (
          SELECT uid FROM platform.ocsf_devices
          WHERE agent_id = rec.agent_id AND uid != canonical_uid
        );

        UPDATE platform.timeseries_metrics
        SET device_id = canonical_uid
        WHERE device_id IN (
          SELECT uid FROM platform.ocsf_devices
          WHERE agent_id = rec.agent_id AND uid != canonical_uid
        );

        UPDATE platform.device_identifiers
        SET device_id = canonical_uid
        WHERE device_id IN (
          SELECT uid FROM platform.ocsf_devices
          WHERE agent_id = rec.agent_id AND uid != canonical_uid
        );

        UPDATE platform.device_alias_states
        SET device_id = canonical_uid
        WHERE device_id IN (
          SELECT uid FROM platform.ocsf_devices
          WHERE agent_id = rec.agent_id AND uid != canonical_uid
        );

        UPDATE platform.device_updates
        SET device_id = canonical_uid
        WHERE device_id IN (
          SELECT uid FROM platform.ocsf_devices
          WHERE agent_id = rec.agent_id AND uid != canonical_uid
        );

        -- Update agent record to point to canonical device
        UPDATE platform.ocsf_agents
        SET device_uid = canonical_uid
        WHERE uid = rec.agent_id AND device_uid != canonical_uid;

        -- Delete duplicate devices
        DELETE FROM platform.ocsf_devices
        WHERE agent_id = rec.agent_id AND uid != canonical_uid;

        RAISE NOTICE 'Consolidated agent % to device %', rec.agent_id, canonical_uid;
      END LOOP;
    END;
    $$;
    """)

    # Step 2: Backfill agent_id identifiers for all devices that have agent_id
    # set on ocsf_devices but no corresponding row in device_identifiers
    execute("""
    INSERT INTO platform.device_identifiers (device_id, identifier_type, identifier_value, partition, confidence, source, first_seen, last_seen)
    SELECT
      d.uid,
      'agent_id',
      d.agent_id,
      'default',
      'strong',
      'migration_backfill',
      NOW(),
      NOW()
    FROM platform.ocsf_devices d
    WHERE d.agent_id IS NOT NULL
      AND d.agent_id != ''
      AND NOT EXISTS (
        SELECT 1 FROM platform.device_identifiers di
        WHERE di.device_id = d.uid
          AND di.identifier_type = 'agent_id'
          AND di.identifier_value = d.agent_id
      )
    ON CONFLICT DO NOTHING;
    """)
  end

  def down do
    # Backfill rows are identifiable by source
    execute("""
    DELETE FROM platform.device_identifiers
    WHERE source = 'migration_backfill'
      AND identifier_type = 'agent_id';
    """)
  end
end
