defmodule ServiceRadar.Repo.Migrations.BackfillDeviceTypeFromIntegrationMetadata do
  @moduledoc false
  use Ecto.Migration

  def up do
    # serviceradar:allow-startup-maintenance - bounded metadata-derived backfill for devices
    # still typed as Unknown; required so existing inventory rows feed the new type rollups.
    execute("""
    WITH candidates AS (
      SELECT
        d.uid,
        alias_value.device_type,
        lower(regexp_replace(alias_value.device_type, '[^a-zA-Z0-9]+', '_', 'g')) AS normalized_type
      FROM platform.ocsf_devices AS d
      CROSS JOIN LATERAL (
        SELECT trim(value) AS device_type
        FROM (
          VALUES
            (d.metadata->>'type'),
            (d.metadata->>'device_type'),
            (d.metadata->>'deviceType'),
            (d.metadata->>'type_name'),
            (d.metadata->>'deviceTypeName'),
            (d.metadata->>'armis_type'),
            (d.metadata->>'netbox_device_type'),
            (d.metadata->>'netbox_role'),
            (d.metadata->>'ansible_device_type'),
            (d.metadata->>'proxmox_type'),
            (d.metadata->>'proxmox_node_type'),
            (d.metadata->>'vm_type'),
            (d.metadata->>'device_role'),
            (d.metadata->>'deviceRole'),
            (d.metadata->>'role'),
            (d.metadata->>'category'),
            (d.metadata->>'armis_category')
        ) AS aliases(value)
        WHERE trim(COALESCE(value, '')) <> ''
          AND lower(trim(value)) NOT IN ('unknown', 'n/a', 'na', 'none', 'null', 'unspecified')
        LIMIT 1
      ) AS alias_value
      WHERE d.deleted_at IS NULL
        AND COALESCE(NULLIF(trim(d.type), ''), 'Unknown') = 'Unknown'
    )
    UPDATE platform.ocsf_devices AS d
    SET
      type = candidates.device_type,
      type_id = CASE
        WHEN candidates.normalized_type IN ('server', 'server_system') THEN 1
        WHEN candidates.normalized_type IN ('desktop', 'desktop_computer', 'workstation') THEN 2
        WHEN candidates.normalized_type IN ('laptop', 'notebook') THEN 3
        WHEN candidates.normalized_type IN ('tablet', 'ipad') THEN 4
        WHEN candidates.normalized_type IN ('mobile', 'mobile_phone', 'phone', 'smartphone', 'mobile_device') THEN 5
        WHEN candidates.normalized_type IN ('virtual', 'vm', 'virtual_machine', 'virtual_guest', 'lxc', 'container') THEN 6
        WHEN candidates.normalized_type IN ('iot', 'io_t', 'internet_of_things') THEN 7
        WHEN candidates.normalized_type IN ('browser', 'web_browser') THEN 8
        WHEN candidates.normalized_type IN ('firewall', 'network_firewall') THEN 9
        WHEN candidates.normalized_type IN ('switch', 'switch_l2') THEN 10
        WHEN candidates.normalized_type = 'hub' THEN 11
        WHEN candidates.normalized_type IN ('router', 'gateway') THEN 12
        WHEN candidates.normalized_type IN ('ids', 'intrusion_detection_system') THEN 13
        WHEN candidates.normalized_type IN ('ips', 'intrusion_prevention_system') THEN 14
        WHEN candidates.normalized_type IN ('load_balancer', 'loadbalancer') THEN 15
        ELSE 99
      END,
      metadata = jsonb_set(
        jsonb_set(COALESCE(d.metadata, '{}'::jsonb), '{type}', to_jsonb(candidates.device_type), true),
        '{device_type}',
        to_jsonb(candidates.device_type),
        true
      ),
      modified_time = now()
    FROM candidates
    WHERE d.uid = candidates.uid
    """)

    execute("""
    DO $$
    BEGIN
      IF to_regprocedure('platform.refresh_device_inventory_rollups()') IS NOT NULL THEN
        PERFORM platform.refresh_device_inventory_rollups();
      END IF;
    END
    $$;
    """)
  end

  def down do
    :ok
  end
end
