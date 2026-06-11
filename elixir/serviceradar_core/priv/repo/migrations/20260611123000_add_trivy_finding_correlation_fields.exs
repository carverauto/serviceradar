defmodule ServiceRadar.Repo.Migrations.AddTrivyFindingCorrelationFields do
  @moduledoc false
  use Ecto.Migration

  def up do
    schema_prefix = prefix() || "platform"

    execute("""
    ALTER TABLE #{schema_prefix}.trivy_findings
      ADD COLUMN IF NOT EXISTS log_uuid UUID,
      ADD COLUMN IF NOT EXISTS agent_id TEXT,
      ADD COLUMN IF NOT EXISTS device_uid TEXT,
      ADD COLUMN IF NOT EXISTS resource_kind TEXT,
      ADD COLUMN IF NOT EXISTS resource_namespace TEXT,
      ADD COLUMN IF NOT EXISTS pod_namespace TEXT,
      ADD COLUMN IF NOT EXISTS pod_uid TEXT,
      ADD COLUMN IF NOT EXISTS host_ip TEXT,
      ADD COLUMN IF NOT EXISTS node_name TEXT,
      ADD COLUMN IF NOT EXISTS container_name TEXT,
      ADD COLUMN IF NOT EXISTS owner_kind TEXT,
      ADD COLUMN IF NOT EXISTS owner_name TEXT,
      ADD COLUMN IF NOT EXISTS owner_uid TEXT,
      ADD COLUMN IF NOT EXISTS image_repository TEXT,
      ADD COLUMN IF NOT EXISTS image_tag TEXT,
      ADD COLUMN IF NOT EXISTS image_digest TEXT,
      ADD COLUMN IF NOT EXISTS package_purl TEXT
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_trivy_findings_device
      ON #{schema_prefix}.trivy_findings (device_uid, agent_id)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_trivy_findings_resource
      ON #{schema_prefix}.trivy_findings (resource_namespace, resource_kind, resource_name)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_trivy_findings_image
      ON #{schema_prefix}.trivy_findings (image_repository, image_tag)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_trivy_findings_package_purl
      ON #{schema_prefix}.trivy_findings (package_purl)
      WHERE package_purl IS NOT NULL
    """)
  end

  def down do
    schema_prefix = prefix() || "platform"

    execute("DROP INDEX IF EXISTS #{schema_prefix}.idx_trivy_findings_package_purl")
    execute("DROP INDEX IF EXISTS #{schema_prefix}.idx_trivy_findings_image")
    execute("DROP INDEX IF EXISTS #{schema_prefix}.idx_trivy_findings_resource")
    execute("DROP INDEX IF EXISTS #{schema_prefix}.idx_trivy_findings_device")

    execute("""
    ALTER TABLE #{schema_prefix}.trivy_findings
      DROP COLUMN IF EXISTS package_purl,
      DROP COLUMN IF EXISTS image_digest,
      DROP COLUMN IF EXISTS image_tag,
      DROP COLUMN IF EXISTS image_repository,
      DROP COLUMN IF EXISTS owner_uid,
      DROP COLUMN IF EXISTS owner_name,
      DROP COLUMN IF EXISTS owner_kind,
      DROP COLUMN IF EXISTS container_name,
      DROP COLUMN IF EXISTS node_name,
      DROP COLUMN IF EXISTS host_ip,
      DROP COLUMN IF EXISTS pod_uid,
      DROP COLUMN IF EXISTS pod_namespace,
      DROP COLUMN IF EXISTS resource_namespace,
      DROP COLUMN IF EXISTS resource_kind,
      DROP COLUMN IF EXISTS device_uid,
      DROP COLUMN IF EXISTS agent_id,
      DROP COLUMN IF EXISTS log_uuid
    """)
  end
end
