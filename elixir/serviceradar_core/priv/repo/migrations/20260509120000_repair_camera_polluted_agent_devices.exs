defmodule ServiceRadar.Repo.Migrations.RepairCameraPollutedAgentDevices do
  @moduledoc false
  use Ecto.Migration

  def up do
    execute("""
    UPDATE platform.ocsf_devices AS d
    SET
      name = CASE
        WHEN d.name = cs.display_name THEN COALESCE(NULLIF(d.hostname, ''), NULLIF(d.ip, ''), d.uid)
        ELSE d.name
      END,
      vendor_name = CASE
        WHEN lower(COALESCE(d.vendor_name, '')) = lower(COALESCE(cs.vendor, '')) THEN NULL
        ELSE d.vendor_name
      END,
      model = CASE
        WHEN COALESCE(d.metadata, '{}'::jsonb) ? 'camera_metadata' THEN NULL
        ELSE d.model
      END,
      metadata = COALESCE(d.metadata, '{}'::jsonb)
        - 'camera_metadata'
        - 'camera_source_url'
        - 'camera_vendor_camera_id'
        - 'camera_host',
      modified_time = now()
    FROM platform.camera_sources AS cs
    WHERE cs.device_uid = d.uid
      AND lower(COALESCE(d.type, '')) <> 'camera'
      AND COALESCE(d.type_id, 0) <> 7
      AND (
        d.agent_id IS NOT NULL
        OR COALESCE(d.discovery_sources, ARRAY[]::text[]) && ARRAY['agent', 'sysmon', 'system_monitor']::text[]
      )
      AND (
        COALESCE(d.metadata, '{}'::jsonb) ? 'camera_metadata'
        OR COALESCE(d.metadata, '{}'::jsonb) ? 'camera_source_url'
        OR COALESCE(d.metadata, '{}'::jsonb) ? 'camera_vendor_camera_id'
        OR COALESCE(d.metadata, '{}'::jsonb) ? 'camera_host'
        OR d.name = cs.display_name
        OR lower(COALESCE(d.vendor_name, '')) = lower(COALESCE(cs.vendor, ''))
      )
    """)
  end

  def down do
    :ok
  end
end
